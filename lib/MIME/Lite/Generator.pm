package MIME::Lite::Generator;

use strict;
use warnings;
use Carp;
use FileHandle;
use MIME::Lite;

our $VERSION = 0.01;

sub new {
	my ( $class, $msg, $is_smtp ) = @_;
	
	my $encoding = uc( $msg->{Attrs}{'content-transfer-encoding'} );
	my $chunk_getter;
	if (defined( $msg->{Path} ) || defined( $msg->{FH} ) || defined ( $msg->{Data} )) {
		if ($encoding eq 'BINARY') {
			$chunk_getter = defined ( $msg->{Data} )
		                     ? 'get_encoded_chunk_data_other'
		                     : 'get_encoded_chunk_fh_binary';
		}
		elsif ($encoding eq '8BIT') {
			$chunk_getter = defined ( $msg->{Data} )
			                 ? 'get_encoded_chunk_data_other'
			                 : 'get_encoded_chunk_fh_8bit';
		}
		elsif ($encoding eq '7BIT') {
			$chunk_getter = defined ( $msg->{Data} )
			                 ? 'get_encoded_chunk_data_other'
			                 : 'get_encoded_chunk_fh_7bit';
		}
		elsif ($encoding eq 'QUOTED-PRINTABLE') {
			$chunk_getter = defined ( $msg->{Data} )
			                 ? 'get_encoded_chunk_data_qp'
			                 : 'get_encoded_chunk_fh_qp';
		}
		elsif ($encoding eq 'BASE64') {
			$chunk_getter = defined ( $msg->{Data} )
			                 ? 'get_encoded_chunk_data_other'
			                 : 'get_encoded_chunk_fh_base64';
		}
		else {
			$chunk_getter = 'get_encoded_chunk_unknown';
		}
	}
	else {
		$chunk_getter = 'get_encoded_chunk_nodata';
	}
	
	bless {
		msg		  => $msg,
		is_smtp	  => $is_smtp,
		generators   => [],
		has_chunk	=> 0,
		state		=> 'init',
		encoding	 => $encoding,
		chunk_getter => $chunk_getter,
		last		 => '',
	}, ref($class) ? ref($class) : $class;
}

sub get {
	my $self = shift;
	
	### Do we have generators for embedded/main part(s)
	while (@{ $self->{generators} }) {
		my $str_ref = $self->{generators}[0]->get();
		return $str_ref if $str_ref;
		
		shift @{ $self->{generators} };
		
		if ($self->{boundary}) {
			if (@{ $self->{generators} }) {
				return \"\n--$self->{boundary}\n";
			}
			
			### Boundary at the end
			return \"\n--$self->{boundary}--\n";
		}
	}
	
	### What we should to generate
	if ($self->{state} eq 'init') {
		my $attrs = $self->{msg}{Attrs};
		my $sub_attrs = $self->{msg}{SubAttrs};
		my $rv;
		$self->{state} = 'first';
		
		### Output either the body or the parts.
		###   Notice that we key off of the content-type!  We expect fewer
		###   accidents that way, since the syntax will always match the MIME type.
		my $type = $attrs->{'content-type'};
		if ( $type =~ m{^multipart/}i ) {
			$self->{boundary} = $sub_attrs->{'content-type'}{'boundary'};

			### Preamble:
			$rv = \($self->{msg}->header_as_string . "\n" . (
					defined( $self->{msg}{Preamble} )
					  ? $self->{msg}{Preamble}
					  : "This is a multi-part message in MIME format.\n"
					) .
					 "\n--$self->{boundary}\n");

			### Parts:
			my $part;
			foreach $part ( @{ $self->{msg}{Parts} } ) {
				push @{ $self->{generators} }, $self->new($part, $self->{out}, $self->{is_smtp});
			}
		}
		elsif ( $type =~ m{^message/} ) {
			my @parts = @{ $self->{msg}{Parts} };

			### It's a toss-up; try both data and parts:
			if ( @parts == 0 ) {
				$self->{has_chunk} = 1;
				$rv = $self->get_encoded_chunk()
			}
			elsif ( @parts == 1 ) { 
				$self->{generators}[0] = $self->new($parts[0], $self->{out}, $self->{is_smtp});
				$rv = $self->{generators}[0]->get();
			}
			else {
				Carp::croak "can't handle message with >1 part\n";
			}
		}
		else {
			$self->{has_chunk} = 1;
			$rv = $self->get_encoded_chunk();
		}
		
		return $rv;
	}
	
	return $self->{has_chunk} ? $self->get_encoded_chunk() : undef;
}

sub get_encoded_chunk {
	my $self = shift;
	
	if ($self->{state} eq 'first') {
		$self->{state} = '';
		### Open file if necessary:
		unless (defined $self->{msg}{Data}) {
			if ( defined( $self->{msg}{Path} ) ) {
				$self->{fh} = new FileHandle || Carp::croak "can't get new filehandle\n";
				$self->{fh}->open($self->{msg}{Path})
					or Carp::croak "open $self->{msg}{Path}: $!\n";
			}
			else {
				$self->{fh} = $self->{msg}{FH};
			}
			CORE::binmode($self->{fh}) if $self->{msg}->binmode;
		}
		
		### Headers first
		return \($self->{msg}->header_as_string . "\n");
	}
	
	my $chunk_getter = $self->{chunk_getter};
	$self->$chunk_getter();
}

sub get_encoded_chunk_data_qp {
	my $self = shift;
	
	### Encode it line by line:
	if ($self->{msg}{Data} =~ m{^(.*[\r\n]*)}smg) {
		my $line = $1; # copy to avoid weird bug; rt 39334
		return \MIME::Lite::encode_qp($line);
	}
	
	$self->{has_chunk} = 0;
	return;
}

sub get_encoded_chunk_data_other {
	my $self = shift;
	$self->{has_chunk} = 0;
	
	if ($self->{encoding} eq 'BINARY') {
		$self->{is_smtp} and $self->{msg}{Data} =~ s/(?!\r)\n\z/\r/;
		return \$self->{msg}{Data};
	}
	
	if ($self->{encoding} eq '8BIT') {
		return \MIME::Lite::encode_8bit( $self->{msg}{Data} );
	}
	
	if ($self->{encoding} eq '7BIT') {
		return \MIME::Lite::encode_7bit( $self->{msg}{Data} );
	}
	
	if ($self->{encoding} eq 'BASE64') {
		return \MIME::Lite::encode_base64( $self->{msg}{Data} );
	}
}

sub get_encoded_chunk_fh_binary {
	my $self = shift;
	my $rv;
	
	if ( read( $self->{fh}, $_, 2048 ) ) {
		$rv = $self->{last};
		$self->{last} = $_;
	}
	else {
		seek $self->{fh}, 0, 0;
		$self->{has_chunk} = 0;
		if ( length $self->{last} ) {
			$self->{is_smtp} and $self->{last} =~ s/(?!\r)\n\z/\r/;
			$rv = $self->{last};
		}
	}
	
	return defined($rv) ? \$rv : undef;
}

sub get_encoded_chunk_fh_8bit {
	my $self = shift;
	
	if ( defined( $_ = readline( $self->{fh} ) ) ) {
		return \MIME::Lite::encode_8bit($_);
	}
	
	$self->{has_chunk} = 0;
	seek $self->{fh}, 0, 0;
	return;
}

sub get_encoded_chunk_fh_7bit {
	my $self = shift;
	
	if ( defined( $_ = readline( $self->{fh} ) ) ) {
		return \MIME::Lite::encode_7bit($_);
	}
	
	$self->{has_chunk} = 0;
	seek $self->{fh}, 0, 0;
	return;
}

sub get_encoded_chunk_fh_qp {
	my $self = shift;
	
	if ( defined( $_ = readline( $self->{fh} ) ) ) {
		return \MIME::Lite::encode_qp($_);
	}
	
	$self->{has_chunk} = 0;
	seek $self->{fh}, 0, 0;
	return;
}

sub get_encoded_chunk_fh_base64 {
	my $self = shift;
	
	if ( read( $self->{fh}, $_, 45 ) ) {
		return \MIME::Lite::encode_base64($_);
	}
	
	$self->{has_chunk} = 0;
	seek $self->{fh}, 0, 0;
	return;
}

sub get_encoded_chunk_unknown {
	croak "unsupported encoding: `$_[0]->{encoding}'\n";
}

sub get_encoded_chunk_nodata {
	croak "no data in this part\n";
}

1;
