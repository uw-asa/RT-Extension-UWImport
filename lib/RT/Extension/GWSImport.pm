use strict;
use warnings;
package RT::Extension::GWSImport;
use base qw(Class::Accessor);

our $VERSION = '0.01';

=head1 NAME

RT-Extension-GWSImport - Import groups from UW Groups Web Service

=head1 DESCRIPTION

Group import modeled after RT::LDAPImport

=head1 RT VERSION

Works with RT 4.4.4

[Make sure to use requires_rt and rt_too_new in Makefile.PL]

=head1 INSTALLATION

=over

=item C<perl Makefile.PL>

=item C<make>

=item C<make install>

May need root permissions

=item Edit your F</opt/rt4/etc/RT_SiteConfig.pm>

Add this line:

    Plugin('RT::Extension::GWSImport');

=item Clear your mason cache

    rm -rf /opt/rt4/var/mason_data/obj

=item Restart your webserver

=back

=head1 AUTHOR

Bradley Bell E<lt>bradleyb@uw.eduE<gt>

=head1 LICENSE AND COPYRIGHT

This software is Copyright (c) 2019 by Bradley Bell

This is free software, licensed under:

  The GNU General Public License, Version 2, June 1991

=cut

1;
