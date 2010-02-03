package CXGN::CDBI::Auto::SGN::QcReport;
# This class is autogenerated by cdbigen.pl.  Any modification
# by you will be fruitless.

=head1 DESCRIPTION

CXGN::CDBI::Auto::SGN::QcReport - object abstraction for rows in the sgn.qc_report table.

Autogenerated by cdbigen.pl.

=head1 DATA FIELDS

  Primary Keys:
      qc_id

  Columns:
      qc_id
      est_id
      basecaller
      qc_status
      vs_status
      qstart
      qend
      istart
      iend
      hqi_start
      hqi_length
      entropy
      expected_error
      quality_trim_threshold
      vector_tokens

  Sequence:
      none

=cut

use base 'CXGN::CDBI::Class::DBI';
__PACKAGE__->table( 'sgn.qc_report' );

our @primary_key_names =
    qw/
      qc_id
      /;

our @column_names =
    qw/
      qc_id
      est_id
      basecaller
      qc_status
      vs_status
      qstart
      qend
      istart
      iend
      hqi_start
      hqi_length
      entropy
      expected_error
      quality_trim_threshold
      vector_tokens
      /;

__PACKAGE__->columns( Primary => @primary_key_names, );
__PACKAGE__->columns( All     => @column_names,      );


=head1 AUTHOR

cdbigen.pl

=cut

###
1;#do not remove
###
