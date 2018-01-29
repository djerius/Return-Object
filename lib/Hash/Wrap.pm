package Hash::Wrap;

# ABSTRACT: create lightweight on-the-fly objects from hashes

use 5.008009;

use strict;
use warnings;

use Scalar::Util qw[ blessed ];
use MRO::Compat;
use Digest::SHA;

our $VERSION = '0.04';

use Hash::Wrap::Base;

our @EXPORT = qw[ wrap_hash ];

my %REGISTRY;

sub _croak {

    require Carp;
    Carp::croak( @_ );
}

sub _find_sub {

    my ( $object, $sub ) = @_;

    my $package = blessed( $object ) || $object;

    no strict 'refs';  ## no critic (ProhibitNoStrict)


    my $mro = mro::get_linear_isa( $package );

    for my $module ( @$mro ) {
        my $candidate = *{"$module\::$sub"}{SCALAR};

        return $$candidate if defined $candidate && 'CODE' eq ref $$candidate;
    }

    _croak( "Unable to find sub reference \$$sub for class $package\n" );

}

# this is called only if the method doesn't exist.
sub _generate_accessor {

    my ( $object, $method, $key ) = @_;

    my $package = blessed( $object ) || $object;

    my ( $signature, $body ) = map _find_sub( $object, "generate_$_" ),
      qw[ signature body ];

    # $code = eval "sub : lvalue { ... }" will invoke the sub as it is
    # used as an lvalue inside of the eval, so set it equal to a variable
    # to ensure it's an rvalue

    my $code = q[
      do {
        package <<PACKAGE>>;
        my $coderef =
          sub <<SIGNATURE>> {
            <<BODY>>
          }
      }
    ];

    _interpolate(
        \$code,
        package   => $package,
        signature => $signature->( $object, $method, $key ),
        body      => $body->( $object, $method, $key ),
    );


    my $coderef = eval $code;    ## no critic (ProhibitStringyEval)

    _croak( qq[error compiling accessor: $@\n $code \n] )
      if $@;

    no strict 'refs';            ## no critic (ProhibitNoStrict)
    *{$method} = $coderef;

    return *{$method}{CODE};
}

sub _autoload {

    my ( $method, $object ) = @_;

    ( my $key = $method ) =~ s/.*:://;

    _croak( qq[Can't locate class method "$key" via package @{[ ref $object]} \n] )
      unless  Scalar::Util::blessed( $object );

    # we're here because there's no slot in the hash for $key.
    #
    unless ( _find_sub( $object, 'validate_key' )->( $object, $key ) ) {
        _croak(
            qq[Can't locate object method "$key" via package @{[ ref $object]} \n]
        );
    }

    _generate_accessor( $object, $method, $key );
}


sub import {

    my ( $me ) = shift;
    my $caller = caller;

    my @imports = @_;

    push @imports, @EXPORT unless @imports;

    for my $args ( @imports ) {

        if ( !ref $args ) {
            _croak( "$args is not exported by ", __PACKAGE__, "\n" )
              unless grep { /$args/ } @EXPORT;

            $args = { -as => $args };
        }

        elsif ( 'HASH' ne ref $args ) {
            _croak(
                "argument to ",
                __PACKAGE__,
                "::import must be string or hash\n"
            ) unless grep { /$args/ } @EXPORT;
        }
        else {
            # make a copy as it gets modified later on
            $args = { %$args };
        }

        my $name = exists $args->{-as} ? delete $args->{-as} : 'wrap_hash';

        my $sub = _generate_wrap_hash( $me, $name, {%$args} );

        no strict 'refs';    ## no critic (ProhibitNoStrict)
        *{"$caller\::$name"} = $sub;
    }

}

sub _generate_wrap_hash {

    my ( $me ) = shift;
    my ( $name, $args ) = @_;

    # closure for user provided clone sub
    my $clone;

    my ( @pre_code, @post_code );

    _croak( "lvalue accessors require Perl 5.16 or later\n" )
      if $args->{-value} && $] lt '5.016000';

    _croak( "cannot mix -copy and -clone\n" )
      if exists $args->{-copy} && exists $args->{-clone};


    if ( delete $args->{-copy} ) {
        push @pre_code, '$hash = { %{ $hash } };';
    }
    elsif ( exists $args->{-clone} ) {

        if ( 'CODE' eq ref $args->{-clone} ) {
            $clone = $args->{-clone};
            push @pre_code, '$hash = $clone->($hash);';
        }
        else {
            require Storable;
            push @pre_code, '$hash = Storable::dclone $hash;';
        }

        delete $args->{-clone};
    }

    my $class;

    if ( defined $args->{-class} && !$args->{-create} ) {
        $class = $args->{-class};

        _croak( qq[class ($class) is not a subclass of Hash::Wrap::Base\n] )
          unless $class->isa( 'Hash::Wrap::Base' );

        if ( $args->{-lvalue} ) {
            my $signature = _find_sub( $class, 'generate_signature' )->();
            _croak( "signature generator for $class does not add ':lvalue'\n" )
              unless defined $signature && $signature =~ /:\s*lvalue/;
        }
    }
    else {
        $class = _build_class( $args );
    }

    my $construct = 'my $obj = ' . do {

        if ( $class->can( 'new' ) ) {
            qq[$class->new(\$hash);];
        }
        elsif ( $args->{-fields} ) {
            qq[do { require fields; fields::new( $class ); } ];
        }

        else {
            qq[bless \$hash, '$class';];
        }

    };

    #<<< no tidy
    my $code = qq[
    sub (\$) {
      my \$hash = shift;
      if ( ! 'HASH' eq ref \$hash ) { _croak( "argument to $name must be a hashref\n" ) }
      <<PRECODE>>
      <<CONSTRUCT>>
      <<POSTCODE>>
      return \$obj;
      };
    ];
    #>>>

    _interpolate( \$code,
                  precode => join( "\n", @pre_code ),
                  construct => $construct,
                  postcode => join( "\n", @post_code ),
                );


    # clean out the rest of the known attributes
    delete @{$args}{qw[ -lvalue -create -class -fields ]};

    if ( keys %$args ) {
        _croak( "unknown options passed to ",
            __PACKAGE__, "::import: ", join( ', ', keys %$args ), "\n" );
    }

    return eval( $code ) ## no critic (ProhibitStringyEval)
      || _croak( "error generating wrap_hash subroutine: $@" );
}

# our bizarre little role emulator.  except our roles have no methods, just lexical subs.  whee!
sub _build_class {

    my $attr = shift;

    my $class = $attr->{-class};

    if ( !defined $class ) {

        my @class = map { (my $attr = $_)  =~ s/-//; $attr } sort keys %$attr;

        if ( $attr->{-fields} ) {
            push @class, sha256_hex( join( $;, sort @{ $attr->{-fields} } ) );
        }

        $class = join '::', 'Hash::Wrap::Class', @class;
    }

    return $class if $REGISTRY{$class};

    my %code = (
        class         => $class,
        signature     => '',
        body          => '',
        autoload_attr => '',
        fields        => '',
        validate      => '',
    );

    if ( $attr->{-lvalue} ) {

        $code{autoload_attr} = ': lvalue';
        $code{signature} = 'our $generate_signature = sub { q[: lvalue]; };';
    }

    if ( $attr->{-fields} ) {
        _croak( "must specify fields as an arrayref\n" )
          if ref $attr->{-fields} ne 'ARRAY';

        require B;
        $code{fields}
          = "use fields qw( @{[ join( ',', map { B::perlstring( $_ ) } @{ $attr->{-fields} } ) ]} );";
    }

    my $class_template = <<'END';
package <<CLASS>>;

use Scalar::Util ();

<<FIELDS>>
our @ISA = ( 'Hash::Wrap::Base' );

<<SIGNATURE>>

<<BODY>>

<<VALIDATE>>

our $AUTOLOAD;
sub AUTOLOAD <<AUTOLOAD_ATTR>> {
    goto &{ Hash::Wrap::_autoload( $AUTOLOAD, $_[0] ) };
}

1;
END
    _interpolate( \$class_template, %code );

    eval( $class_template )  ## no critic (ProhibitStringyEval)
      or _croak( "error generating class $class: $@" );


    $REGISTRY{$class}++;

    return $class;
}

sub _interpolate {

    my ( $tpl, $dict, $work ) = @_;

    $work = { loop => {} } unless defined $work;

    $$tpl =~ s{ \<\<(\w+)\>\>
              }{
                  my $key = lc $1;
                  my $v = $dict->{$key};
                  if ( defined $v ) {
                      _croak( "circular interpolation loop detected for $key\n" )
                        if $work->{loop}{$key}++;
                      _interpolate( \$v, $dict, $work );
                      --$work->{loop}{$key};
                 }
                 $v;
              }gex;
    return;
}


1;

# COPYRIGHT

__END__


=head1 SYNOPSIS


  use Hash::Wrap;

  sub foo {
    wrap_hash { a => 1 };
  }

  $result = foo();
  print $result->a;  # prints
  print $result->b;  # throws

  # create two constructors, <cloned> and <copied> with different
  # behaviors. does not import C<wrap_hash>
  use Hash::Wrap
    { -as => 'cloned', clone => 1},
    { -as => 'copied', copy => 1 };

=head1 DESCRIPTION


This module provides constructors which create light-weight objects
from existing hashes, allowing access to hash elements via methods
(and thus avoiding typos). Attempting to access a non-existent element
via a method will result in an exception.

Hash elements may be added to or deleted from the object after
instantiation using the standard Perl hash operations, and changes
will be reflected in the object's methods. For example,

   $obj = wrap_hash( { a => 1, b => 2 );
   $obj->c; # throws exception
   $obj->{c} = 3;
   $obj->c; # returns 3
   delete $obj->{c};
   $obj->c; # throws exception


To prevent modification of the hash, consider using the lock routines
in L<Hash::Util> on the object.

The methods act as both accessors and setters, e.g.

  $obj = wrap_hash( { a => 1 } );
  print $obj->a; # 1
  $obj->a( 3 );
  print $obj->a; # 3

Only hash keys which are legal method names will be accessible via
object methods.

=head2 Object construction and constructor customization

By default C<Hash::Wrap> exports a C<wrap_hash> subroutine which,
given a hashref, blesses it directly into the B<Hash::Wrap::Class>
class.

The constructor may be customized to change which class the object is
instantiated from, and how it is constructed from the data.
For example,

  use Hash::Wrap
    { -as => 'return_cloned_object', -clone => 1 };

will create a constructor which clones the passed hash
and is imported as C<return_cloned_object>.  To import it under
the original name, C<wrap_hash>, leave out the C<-as> option.

The following options are available to customize the constructor.

=over

=item C<-as> => I<subroutine name>

This is optional, and imports the constructor with the given name. If
not specified, it defaults to C<wrap_hash>.

=item C<-class> => I<class name>

The object will be blessed into the specified class.  If the class
should be created on the fly, specify the C<-create> option.
See L</Object Classes> for what is expected of the object classes.
This defaults to C<Hash::Wrap::Class>.

=item C<-create> => I<boolean>

If true, and C<-class> is specified, a class with the given name
will be created.

=item C<-copy> => I<boolean>

If true, the object will store the data in a I<shallow> copy of the
hash. By default, the object uses the hash directly.

=item C<-clone> => I<boolean> | I<coderef>

Store the data in a deep copy of the hash. if I<true>, L<Storable/dclone>
is used. If a coderef, it will be called as

   $clone = coderef->( $hash )

By default, the object uses the hash directly.

=item C<-lvalue> => I<boolean>

If true, the accessors will be lvalue routines, e.g. they can
change the underlying hash value by assigning to them:

   $obj->attr = 3;

The hash entry must already exist before using the accessor in
this manner, or it will throw an exception.

This is only available on Perl 5.16 and higher.

=back

=head2 Object Classes

An object class has the following properties:

=over

=item *

The class must be a subclass of C<Hash::Wrap::Base>.

=item *

The class typically does not provide any methods, as they would mask
a hash key of the same name.

=item *

The class need not have a constructor.  If it does, it is passed a
hashref which it should bless as the actual object.  For example:

  package My::Result;
  use parent 'Hash::Wrap::Base';

  sub new {
    my  ( $class, $hash ) = @_;
    return bless $hash, $class;
  }

This excludes having a hash key named C<new>.

=back

C<Hash::Wrap::Base> provides an empty C<DESTROY> method, a
C<can> method, and an C<AUTOLOAD> method.  They will mask hash
keys with the same names.

=head1 LIMITATIONS

=over

=item *

Lvalue accessors are available only on Perl 5.16 and later.

=back

=head1 SEE ALSO

Here's a comparison of this module and others on CPAN.


=over

=item L<Hash::Wrap> (this module)

=over

=item * core dependencies only

=item * only applies object paradigm to top level hash

=item * accessors may be lvalue subroutines

=item * accessing a non-existing element via an accessor throws

=item * can use custom package

=item * can copy/clone existing hash. clone may be customized

=back


=item L<Object::Result>

As you might expect from a
L<DCONWAY|https://metacpan.org/author/DCONWAY> module, this does just
about everything you'd like.  It has a very heavy set of dependencies.

=item L<Hash::AsObject>

=over

=item * core dependencies only

=item * applies object paradigm recursively

=item * accessing a non-existing element via an accessor creates it

=back

=item L<Data::AsObject>

=over

=item * moderate dependency chain (no XS?)

=item * applies object paradigm recursively

=item * accessing a non-existing element throws

=back

=item L<Class::Hash>

=over

=item * core dependencies only

=item * only applies object paradigm to top level hash

=item * can add generic accessor, mutator, and element management methods

=item * accessing a non-existing element via an accessor creates it (not documented, but code implies it)

=item * C<can()> doesn't work

=back

=item L<Hash::Inflator>

=over

=item * core dependencies only

=item * accessing a non-existing element via an accessor returns undef

=item * applies object paradigm recursively

=back

=item L<Hash::AutoHash>

=over

=item * moderate dependency chain.  Requires XS, tied hashes

=item * applies object paradigm recursively

=item * accessing a non-existing element via an accessor creates it

=back

=item L<Hash::Objectify>

=over

=item * light dependency chain.  Requires XS.

=item * only applies object paradigm to top level hash

=item * accessing a non-existing element throws, but if an existing
element is accessed, then deleted, accessor returns undef rather than
throwing

=item * can use custom package

=back

=item L<Data::OpenStruct::Deep>

=over

=item * uses source filters

=item * applies object paradigm recursively

=back

=item L<Object::AutoAccessor>

=over

=item * light dependency chain

=item * applies object paradigm recursively

=item * accessing a non-existing element via an accessor creates it

=back

=item L<Data::Object::Autowrap>

=over

=item * core dependencies only

=item * no documentation

=back

=back


