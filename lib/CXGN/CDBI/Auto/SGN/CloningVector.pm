package CXGN::CDBI::Auto::SGN::CloningVector;
# This class is autogenerated by cdbigen.pl.  Any modification
# by you will be fruitless.

=head1 DESCRIPTION

CXGN::CDBI::Auto::SGN::CloningVector - object abstraction for rows in the sgn.cloning_vector table.

Autogenerated by cdbigen.pl.

=head1 DATA FIELDS

  Primary Keys:
      cloning_vector_id

  Columns:
      cloning_vector_id
      name
      seq

  Sequence:
      none

=cut

use base 'CXGN::CDBI::Class::DBI';
__PACKAGE__->table( 'sgn.cloning_vector' );

our @primary_key_names =
    qw/
      cloning_vector_id
      /;

our @column_names =
    qw/
      cloning_vector_id
      name
      seq
      /;

__PACKAGE__->columns( Primary => @primary_key_names, );
__PACKAGE__->columns( All     => @column_names,      );


=head1 AUTHOR

cdbigen.pl

=cut

###
1;#do not remove
###
