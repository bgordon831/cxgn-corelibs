package CXGN::CDBI::Auto::SGN::IlInfo;
# This class is autogenerated by cdbigen.pl.  Any modification
# by you will be fruitless.

=head1 DESCRIPTION

CXGN::CDBI::Auto::SGN::IlInfo - object abstraction for rows in the sgn.il_info table.

Autogenerated by cdbigen.pl.

=head1 DATA FIELDS

  Primary Keys:


  Columns:
      ns_marker_id
      sn_marker_id
      map_id
      map_version_id
      population_id
      ns_position
      sn_position
      name
      ns_alias
      sn_alias
      lg_name

  Sequence:
      none

=cut

use base 'CXGN::CDBI::Class::DBI';
__PACKAGE__->table( 'sgn.il_info' );

our @primary_key_names =
    qw/

      /;

our @column_names =
    qw/
      ns_marker_id
      sn_marker_id
      map_id
      map_version_id
      population_id
      ns_position
      sn_position
      name
      ns_alias
      sn_alias
      lg_name
      /;

__PACKAGE__->columns( Primary => @primary_key_names, );
__PACKAGE__->columns( All     => @column_names,      );


=head1 AUTHOR

cdbigen.pl

=cut

###
1;#do not remove
###
