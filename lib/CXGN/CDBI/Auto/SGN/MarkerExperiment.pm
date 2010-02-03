package CXGN::CDBI::Auto::SGN::MarkerExperiment;
# This class is autogenerated by cdbigen.pl.  Any modification
# by you will be fruitless.

=head1 DESCRIPTION

CXGN::CDBI::Auto::SGN::MarkerExperiment - object abstraction for rows in the sgn.marker_experiment table.

Autogenerated by cdbigen.pl.

=head1 DATA FIELDS

  Primary Keys:
      marker_experiment_id

  Columns:
      marker_experiment_id
      marker_id
      pcr_experiment_id
      rflp_experiment_id
      location_id
      protocol

  Sequence:
      none

=cut

use base 'CXGN::CDBI::Class::DBI';
__PACKAGE__->table( 'sgn.marker_experiment' );

our @primary_key_names =
    qw/
      marker_experiment_id
      /;

our @column_names =
    qw/
      marker_experiment_id
      marker_id
      pcr_experiment_id
      rflp_experiment_id
      location_id
      protocol
      /;

__PACKAGE__->columns( Primary => @primary_key_names, );
__PACKAGE__->columns( All     => @column_names,      );


=head1 AUTHOR

cdbigen.pl

=cut

###
1;#do not remove
###
