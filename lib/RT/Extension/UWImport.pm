use strict;
use warnings;
package RT::Extension::UWImport;
use base qw(Class::Accessor);
__PACKAGE__->mk_accessors(qw(_gws _pws _group _users));
use Carp;
use LWP::UserAgent ();
use JSON;
use Data::Dumper;


our $VERSION = '0.01';

=head1 NAME

RT-Extension-UWImport - Import groups and users from the University of Washington's Groups and Person Web Services

=head1 DESCRIPTION

Modeled after RT::LDAPImport

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

    Plugin('RT::Extension::UWImport');

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

=head1 SYNOPSIS

In C<RT_SiteConfig.pm>:

    Set($GWSHost, 'groups.uw.edu');

    Set($PWSHost, 'groups.uw.edu');

Running the import:

    # Run a test import
    /opt/rt4/local/plugins/bin/rt-uwimport --verbose > uwimport.debug 2>&1
    
    # Run for real, possibly put in cron
    /opt/rt4/local/plugins/bin/rt-uwimport --import

=head1 CONFIGURATION

All of the configuration for the importer goes in
your F<RT_SiteConfig.pm> file.

=over

=item C<< Set($GWSHost, 'groups.uw.edu'); >>

Hostname 

=back

=head1 Mapping Groups Between RT and GWS

If you are using the importer, you likely want to manage access via
GWS by putting people in groups like 'DBAs' and 'IT Support', but
also have groups for other non-RT related things. In this case, you
won't want to create all of your GWS groups in RT. To limit the groups
that get mirrored, construct your C<$GWSGroupFilter> with
all of the RT groups you want to mirror from GWS.

The importer will then import only the groups that match. In this case,
import means:

=over

=item * Verifying the group is in AD;

=item * Creating the group in RT if it doesn't exist;

=item * Populating the group with the members identified in AD;

=back

The import script will also issue a warning if a user isn't found in RT,
but this should only happen when testing. When running with --import on,
users are created before groups are processed, so all users (group
members) should exist unless there are inconsistencies in your GWS configuration.

=head1 Running the Import

Executing C<rt-uwimport> will run a test that connects to your GWS server
and prints out a list of the users found. To see more about these users,
and to see more general debug information, include the C<--verbose> flag.

That debug information is also sent to the RT log with the debug level.
Errors are logged to the screen and to the RT log.

Executing C<rt-uwimport> with the C<--import> flag will cause it to import
users into your RT database. It is recommended that you make a database
backup before doing this. If your filters aren't set properly this could
create a lot of users or groups in your RT instance.

=head1 METHODS

=head2 connect_gws

Relies on the config variable C<$GWSOptions> being set in your RT Config.

 Set($GWSOptions, []);

=cut

sub connect_gws {
    my $self = shift;

    $RT::GWSOptions = [] unless $RT::GWSOptions;
    my $gws = LWP::UserAgent->new(@$RT::GWSOptions);

    $self->_gws($gws);
    return $gws;
}


=head2 connect_pws

Relies on the config variable C<$PWSOptions> being set in your RT Config.

 Set($PWSOptions, []);

=cut

sub connect_pws {
    my $self = shift;

    $RT::PWSOptions = [] unless $RT::PWSOptions;
    my $pws = LWP::UserAgent->new(@$RT::PWSOptions);

    $self->_pws($pws);
    return $pws;
}


=head2 _gws_search

Returns an array of GWS groups or members.

=cut

sub _gws_search {
    my $self = shift;
    my $gws = $self->_gws||$self->connect_gws;
    my %args = @_;

    unless ($gws) {
        $RT::Logger->error("fetching a GWS connection failed");
        return;
    }

    my $search = $args{search};
    my (@results);

    my $result = $gws->get(join('/', ($RT::GWSHost, $search)));

    if (! $result->is_success) {
        $RT::Logger->error("GWS search " . $search . " failed: " . $result->message);
    }

    my $content = decode_json($result->decoded_content);

    push @results, @{$content->{'data'}};

    $RT::Logger->debug("search found ".scalar @results." objects");
    return @results;
}


=head2 _pws_search

Returns a PWS person object.

=cut

sub _pws_search {
    my $self = shift;
    my $pws = $self->_pws||$self->connect_pws;
    my %args = @_;

    unless ($pws) {
        $RT::Logger->error("fetching a PWS connection failed");
        return;
    }

    my $search = $args{search};
    my (@results);

    my $result = $pws->get(join('/', ($RT::PWSHost, $search)));

    if (! $result->is_success) {
        $RT::Logger->warning("PWS search " . $search . " failed: " . $result->message);
        return undef;
    }

    return decode_json($result->decoded_content);
}


=head2 import_users import => 1|0

Takes the results of the search from pws_search
and maps attributes from GWS into C<RT::User> attributes
using C<$GWSMapping>.
Creates RT users if they don't already exist.

With no arguments, only prints debugging information.
Pass C<--import> to actually change data.

C<$GWSMapping>> should be set in your C<RT_SiteConfig.pm>
file and look like this.

 Set($GWSMapping, { RTUserField => GWSField, RTUserField => GWSField });

RTUserField is the name of a field on an C<RT::User> object
GWSField can be a simple scalar and that attribute
will be looked up in GWS.

It can also be an arrayref, in which case each of the
elements will be evaluated in turn.  Scalars will be
looked up in GWS and concatenated together with a single
space.

If the value is a sub reference, it will be executed.
The sub should return a scalar, which will be examined.
If it is a scalar, the value will be looked up in GWS.
If it is an arrayref, the values will be concatenated 
together with a single space.

By default users are created as Unprivileged, but you can change this by
setting C<$GWSCreatePrivileged> to 1.

=cut

sub _import_users {
    my $self = shift;
    my %args = @_;
    my $users = $args{users};

    unless ( @$users ) {
        $RT::Logger->debug("No users found, no import");
        return;
    }

    my $done = 0; my $count = scalar @$users;
    while (my $entry = shift @$users) {
        my $user = $self->_build_user_object( pws_entry => $entry );
        $self->_import_user( user => $user, pws_entry => $entry, import => $args{import} );
        $done++;
        $RT::Logger->debug("Imported $done/$count users");
    }
    return 1;
}

=head2 _import_user

We have found a user to attempt to import; returns the L<RT::User>
object if it was found (or created), C<undef> if not.

=cut

sub _import_user {
    my $self = shift;
    my %args = @_;

    unless ( $args{user}{Name} ) {
        $RT::Logger->warn("No Name or Emailaddress for user, skipping ".Dumper($args{user}));
        return;
    }
    if ( $args{user}{Name} =~ /^[0-9]+$/) {
        $RT::Logger->debug("Skipping user '$args{user}{Name}', as it is numeric");
        return;
    }

    $RT::Logger->debug("Processing user $args{user}{Name}");
    $self->_cache_user( %args );

    $args{user} = $self->create_rt_user( %args );
    return unless $args{user};

    $self->add_user_to_group( %args );

    return $args{user};
}

=head2 _cache_user pws_entry => PWS Entry, [user => { ... }]

Adds the user to a global cache which is used when importing groups later.

Optionally takes a second argument which is a user data object returned by
_build_user_object.  If not given, _cache_user will call _build_user_object
itself.

Returns the user Name.

=cut

sub _cache_user {
    my $self = shift;
    my %args = (@_);
    my $user = $args{user} || $self->_build_user_object( pws_entry => $args{pws_entry} );

    $self->_users({}) if not defined $self->_users;

    my $membership_key  = $args{pws_entry}->{UWNetID};

    return $self->_users->{lc $membership_key} = $user->{Name};
}

sub _show_user_info {
    my $self = shift;
    my %args = @_;
    my $user = $args{user};
    my $rt_user = $args{rt_user};

    $RT::Logger->debug( "\tRT Field\tRT Value -> GWS Value" );
    foreach my $key (sort keys %$user) {
        my $old_value;
        if ($rt_user) {
            eval { $old_value = $rt_user->$key() };
            if ($user->{$key} && defined $old_value && $old_value eq $user->{$key}) {
                $old_value = 'unchanged';
            }
        }
        $old_value ||= 'unset';
        $RT::Logger->debug( "\t$key\t$old_value => $user->{$key}" );
    }
}

=head2 _build_user_object

Utility method which builds RT user data from PWS entry.

=cut

sub _build_user_object {
    my $self = shift;
    my %args = @_;
    my $entry = $args{pws_entry};

    my $user = {
        Name            => $entry->{UWNetID},
        RealName        => $entry->{DisplayName},
        EmailAddress    => $entry->{PersonAffiliations}{EmployeePersonAffiliation}{EmployeeWhitePages}{EmailAddresses}[0],
        WorkPhone       => $entry->{PersonAffiliations}{EmployeePersonAffiliation}{EmployeeWhitePages}{Phones}[0],
        MobilePhone     => $entry->{PersonAffiliations}{EmployeePersonAffiliation}{EmployeeWhitePages}{Mobiles}[0],
        PagerPhone      => $entry->{PersonAffiliations}{EmployeePersonAffiliation}{EmployeeWhitePages}{Pagers}[0],
        Organization    => $entry->{PersonAffiliations}{EmployeePersonAffiliation}{HomeDepartment},
    };

    # delete empty keys
    foreach (keys %$user) {
        delete $user->{$_} unless defined $user->{$_};
    }

    $user->{EmailAddress} ||= $entry->{UWNetID} . '@uw.edu';
    return $user;
}


=head2 create_rt_user

Takes a hashref of args to pass to C<RT::User::Create>
Will try loading the user and will only create a new
user if it can't find an existing user with the C<Name>
or C<EmailAddress> arg passed in.

If the C<$PWSUpdateUsers> variable is true, data in RT
will be clobbered with data in GWS.  Otherwise we
will skip to the next user.

If C<$PWSUpdateOnly> is true, we will not create new users
but we will update existing ones.

=cut

sub create_rt_user {
    my $self = shift;
    my %args = @_;
    my $user = $args{user};

    my $user_obj = $self->_load_rt_user(%args);

    if ($user_obj->Id) {
        my $message = "User $user->{Name} already exists as ".$user_obj->Id;
        if ($RT::PWSUpdateUsers || $RT::PWSUpdateOnly) {
            $RT::Logger->debug("$message, updating their data");
            if ($args{import}) {
                my @results = $user_obj->Update( ARGSRef => $user, AttributesRef => [keys %$user] );
                $RT::Logger->debug(join("\n",@results)||'no change');
            } else {
                $RT::Logger->debug("Found existing user $user->{Name} to update");
                $self->_show_user_info( %args, rt_user => $user_obj );
            }
        } else {
            $RT::Logger->debug("$message, skipping");
        }
    } else {
        if ( $RT::PWSUpdateOnly ) {
            $RT::Logger->debug("User $user->{Name} doesn't exist in RT, skipping");
            return;
        } else {
            if ($args{import}) {
                my ($val, $msg) = $user_obj->Create( %$user, Privileged => $RT::GWSCreatePrivileged ? 1 : 0 );

                unless ($val) {
                    $RT::Logger->error("couldn't create user_obj for $user->{Name}: $msg");
                    return;
                }
                $RT::Logger->debug("Created user for $user->{Name} with id ".$user_obj->Id);
            } else {
                $RT::Logger->debug( "Found new user $user->{Name} to create in RT" );
                $self->_show_user_info( %args );
                return;
            }
        }
    }

    unless ($user_obj->Id) {
        $RT::Logger->error("We couldn't find or create $user->{Name}. This should never happen");
    }
    return $user_obj;

}

sub _load_rt_user {
    my $self = shift;
    my %args = @_;
    my $user = $args{user};

    my $user_obj = RT::User->new($RT::SystemUser);

    $user_obj->Load( $user->{Name} );
    unless ($user_obj->Id) {
        $user_obj->LoadByEmail( $user->{EmailAddress} );
    }

    return $user_obj;
}

=head2 add_user_to_group

Adds new users to the group specified in the C<$GWSGroupName>
variable (defaults to 'Imported from GWS').
You can avoid this if you set C<$GWSSkipAutogeneratedGroup>.

=cut

sub add_user_to_group {
    my $self = shift;
    my %args = @_;
    my $user = $args{user};

    return if $RT::GWSSkipAutogeneratedGroup;

    my $group = $self->_group||$self->setup_group;

    my $principal = $user->PrincipalObj;

    if ($group->HasMember($principal)) {
        $RT::Logger->debug($user->Name . " already a member of " . $group->Name);
        return;
    }

    if ($args{import}) {
        my ($status, $msg) = $group->AddMember($principal->Id);
        if ($status) {
            $RT::Logger->debug("Added ".$user->Name." to ".$group->Name." [$msg]");
        } else {
            $RT::Logger->error("Couldn't add ".$user->Name." to ".$group->Name." [$msg]");
        }
        return $status;
    } else {
        $RT::Logger->debug("Would add to ".$group->Name);
        return;
    }
}

=head2 setup_group

Pulls the C<$GWSGroupName> object out of the DB or
creates it if we need to do so.

=cut

sub setup_group  {
    my $self = shift;
    my $group_name = $RT::GWSGroupName||'Imported from GWS';
    my $group = RT::Group->new($RT::SystemUser);

    $group->LoadUserDefinedGroup( $group_name );
    unless ($group->Id) {
        my ($id,$msg) = $group->CreateUserDefinedGroup( Name => $group_name );
        unless ($id) {
            $RT::Logger->error("Can't create group $group_name [$msg]")
        }
    }

    $self->_group($group);
}


=head2 import_groups import => 1|0

Takes the results of the search from C<run_group_search>
and maps attributes from GWS into C<RT::Group> attributes
using C<$GWSGroupMapping>.

Creates groups if they don't exist.

Removes users from groups if they have been removed from the group on GWS.

With no arguments, only prints debugging information.
Pass C<--import> to actually change data.

=cut

sub import_groups {
    my $self = shift;
    my %args = @_;

    my @results = $self->run_group_search;
    unless ( @results ) {
        $RT::Logger->debug("No results found, no group import");
        return;
    }

    my $done = 0; my $count = scalar @results;
    while (my $entry = shift @results) {
        my %group = (
            Name        => $entry->{'id'},
            Description => $entry->{'name'},
            UWRegID     => $entry->{'regid'},
            Member_Attr => [],
        );

        $RT::Logger->debug("finding members of group " . $group{Name});
        my @members = $self->_gws_search(search => 'group/' . $group{Name} . '/effective_member');
        while (my $member = shift @members) {
            if ($member->{'type'} eq 'uwnetid') {
                push @{$group{Member_Attr}}, $member;
            }
            else {
                $RT::Logger->debug("skipping member $member->{id} of type $member->{type}");
            }
        }

        $self->_import_group( %args, group => \%group, gws_entry => $entry );
        $done++;
        $RT::Logger->debug("Imported $done/$count groups");
    }
    return 1;
}


=head3 run_group_search

Set up the appropriate arguments for a listing of users.

=cut

sub run_group_search {
    my $self = shift;

    unless ($RT::GWSGroupStem) {
        $RT::Logger->warn("Not running a group import, configuration not set");
        return;
    }
    $self->_gws_search(
        search => 'search?stem=' . $RT::GWSGroupStem
    );

}


=head2 _import_group

The user has run us with C<--import>, so bring data in.

=cut

sub _import_group {
    my $self = shift;
    my %args = @_;
    my $group = $args{group};
    my $gws_entry = $args{gws_entry};

    $RT::Logger->debug("Processing group $group->{Name}");
    my ($group_obj, $created) = $self->create_rt_group( %args, group => $group );
    return if $args{import} and not $group_obj;
    $self->add_group_members(
        %args,
        name => $group->{Name},
        info => $group,
        group => $group_obj,
        gws_entry => $gws_entry,
        new => $created,
    );
    # XXX TODO: support OCFVs for groups too
    return;
}


=head2 create_rt_group

Takes a hashref of args to pass to C<RT::Group::Create>
Will try loading the group and will only create a new
group if it can't find an existing group with the C<Name>
or C<EmailAddress> arg passed in.

If C<$PWSUpdateOnly> is true, we will not create new groups
but we will update existing ones.

There is currently no way to prevent Group data from being
clobbered from GWS.

=cut

sub create_rt_group {
    my $self = shift;
    my %args = @_;
    my $group = $args{group};

    my $group_obj = $self->find_rt_group(%args);
    return unless defined $group_obj;

    $group = { map { $_ => $group->{$_} } qw(id Name Description) };

    my $regid = delete $group->{'UWRegID'};

    my $created;
    if ($group_obj->Id) {
        if ($args{import}) {
            $RT::Logger->debug("Group $group->{Name} already exists as ".$group_obj->Id.", updating their data");
            my @results = $group_obj->Update( ARGSRef => $group, AttributesRef => [keys %$group] );
            $RT::Logger->debug(join("\n",@results)||'no change');
        } else {
            $RT::Logger->debug( "Found existing group $group->{Name} to update" );
            $self->_show_group_info( %args, rt_group => $group_obj );
        }
    } else {
        if ( $RT::PWSUpdateOnly ) {
            $RT::Logger->debug("Group $group->{Name} doesn't exist in RT, skipping");
            return;
        }

        if ($args{import}) {
            my ($val, $msg) = $group_obj->CreateUserDefinedGroup( %$group );
            unless ($val) {
                $RT::Logger->error("couldn't create group_obj for $group->{Name}: $msg");
                return;
            }
            $created = $val;
            $RT::Logger->debug("Created group for $group->{Name} with id ".$group_obj->Id);

            if ( $regid ) {
                my ($val, $msg) = $group_obj->SetAttribute( Name => 'UWRegID-'.$regid, Content => 1 );
                unless ($val) {
                    $RT::Logger->error("couldn't set attribute: $msg");
                    return;
                }
            }

        } else {
            $RT::Logger->debug( "Found new group $group->{Name} to create in RT" );
            $self->_show_group_info( %args );
            return;
        }
    }

    unless ($group_obj->Id) {
        $RT::Logger->error("We couldn't find or create $group->{Name}. This should never happen");
    }
    return ($group_obj, $created);

}


=head3 find_rt_group

Loads groups by Name and by the specified UWRegID. Attempts to resolve
renames and other out-of-sync failures between RT and GWS.

=cut

sub find_rt_group {
    my $self = shift;
    my %args = @_;
    my $group = $args{group};

    my $group_obj = RT::Group->new($RT::SystemUser);
    $group_obj->LoadUserDefinedGroup( $group->{Name} );
    return $group_obj unless $group->{'UWRegID'};

    unless ( $group_obj->id ) {
        $RT::Logger->debug("No group in RT named $group->{Name}. Looking by $group->{UWRegID} UWRegID.");
        $group_obj = $self->find_rt_group_by_regid( $group->{'UWRegID'} );
        unless ( $group_obj ) {
            $RT::Logger->debug("No group in RT with UWRegID $group->{UWRegID}. Creating a new one.");
            return RT::Group->new($RT::SystemUser);
        }

        $RT::Logger->debug("No group in RT named $group->{Name}, but found group by UWRegID $group->{UWRegID}. Renaming the group.");
        # $group->Update will take care of the name
        return $group_obj;
    }

    my $attr_name = 'UWRegID-'. $group->{'UWRegID'};
    my $rt_gid = $group_obj->FirstAttribute( $attr_name );
    return $group_obj if $rt_gid;

    my $other_group = $self->find_rt_group_by_regid( $group->{'UWRegID'} );
    if ( $other_group ) {
        $RT::Logger->debug("Group with UWRegID $group->{UWRegID} exists, as well as group named $group->{Name}. Renaming both.");
    }
    elsif ( grep $_->Name =~ /^UWRegID-/, @{ $group_obj->Attributes->ItemsArrayRef } ) {
        $RT::Logger->debug("No group in RT with UWRegID $group->{UWRegID}, but group $group->{Name} has id. Renaming the group and creating a new one.");
    }
    else {
        $RT::Logger->debug("No group in RT with UWRegID $group->{UWRegID}, but group $group->{Name} exists and has no UWRegID. Assigning the id to the group.");
        if ( $args{import} ) {
            my ($status, $msg) = $group_obj->SetAttribute( Name => $attr_name, Content => 1 );
            unless ( $status ) {
                $RT::Logger->error("Couldn't set attribute: $msg");
                return undef;
            }
            $RT::Logger->debug("Assigned $group->{UWRegID} UWRegID to $group->{Name}");
        }
        else {
            $RT::Logger->debug( "Group $group->{'Name'} gets UWRegID $group->{UWRegID}" );
        }

        return $group_obj;
    }

    # rename existing group to move it out of our way
    {
        my ($old, $new) = ($group_obj->Name, $group_obj->Name .' (UWImport '. time . ')');
        if ( $args{import} ) {
            my ($status, $msg) = $group_obj->SetName( $new );
            unless ( $status ) {
                $RT::Logger->error("Couldn't rename group from $old to $new: $msg");
                return undef;
            }
            $RT::Logger->debug("Renamed group $old to $new");
        }
        else {
            $RT::Logger->debug( "Group $old to be renamed to $new" );
        }
    }

    return $other_group || RT::Group->new($RT::SystemUser);
}


=head3 find_rt_group_by_regid

Loads an RT::Group by the gws provided id (different from RT's internal group
id)

=cut

sub find_rt_group_by_regid {
    my $self = shift;
    my $regid = shift;

    my $groups = RT::Groups->new( RT->SystemUser );
    $groups->LimitToUserDefinedGroups;
    my $attr_alias = $groups->Join( FIELD1 => 'id', TABLE2 => 'Attributes', FIELD2 => 'ObjectId' );
    $groups->Limit( ALIAS => $attr_alias, FIELD => 'ObjectType', VALUE => 'RT::Group' );
    $groups->Limit( ALIAS => $attr_alias, FIELD => 'Name', VALUE => 'UWRegID-'. $regid );
    return $groups->First;
}


=head3 add_group_members

Iterate over the list of values in the C<Member_Attr> GWS entry.
Look up the appropriate username from PWS.
Add those users to the group.
Remove members of the RT Group who are no longer members
of the GWS group.

=cut

sub add_group_members {
    my $self = shift;
    my %args = @_;
    my $group = $args{group};
    my $groupname = $args{name};
    my $gws_entry = $args{gws_entry};

    $RT::Logger->debug("Processing group membership for $groupname");

    my $members = $args{'info'}{'Member_Attr'};
    unless (defined $members) {
        $RT::Logger->warn("No members found for $groupname in Member_Attr");
        return;
    }

    if ($RT::GWSImportGroupMembers) {
        $RT::Logger->debug("Importing members of group $groupname");
        my @entries;

        # Lookup each netid's full entry
        foreach my $member (@$members) {
            my $entry = $self->_pws_search(
                search  => 'person/' . $member->{'id'} . '/full.json',
            );
            $entry ||= {
                UWNetID => $member->{id},
            };
            push @entries, $entry;
        }

        $self->_import_users(
            import  => $args{import},
            users   => \@entries,
        ) or $RT::Logger->debug("Importing group members failed");
    }

    my %rt_group_members;
    if ($args{group} and not $args{new}) {
        my $user_members = $group->UserMembersObj( Recursively => 0);

        # find members who are Disabled too so we don't try to add them below
        $user_members->FindAllRows;

        while ( my $member = $user_members->Next ) {
            $rt_group_members{$member->Name} = $member;
        }
    } elsif (not $args{import}) {
        $RT::Logger->debug("No group in RT, would create with members:");
    }

    my $users = $self->_users;
    foreach my $member (@$members) {
        my $username;
        if (exists $users->{lc $member}) {
            next unless $username = $users->{lc $member};
        } else {
            $username = $self->_cache_user( pws_entry => { UWNetID => $member->{id} } );
        }
        if ( delete $rt_group_members{$username} ) {
            $RT::Logger->debug("\t$username\tin RT and GWS");
            next;
        }
        $RT::Logger->debug($group ? "\t$username\tin GWS, adding to RT" : "\t$username");
        next unless $args{import};

        my $rt_user = RT::User->new($RT::SystemUser);
        my ($res,$msg) = $rt_user->Load( $username );
        unless ($res) {
            $RT::Logger->warn("Unable to load $username: $msg");
            next;
        }
        ($res,$msg) = $group->AddMember($rt_user->PrincipalObj->Id);
        unless ($res) {
            $RT::Logger->warn("Failed to add $username to $groupname: $msg");
        }
    }

    for my $username (sort keys %rt_group_members) {
        $RT::Logger->debug("\t$username\tin RT, not in GWS, removing");
        next unless $args{import};

        my ($res,$msg) = $group->DeleteMember($rt_group_members{$username}->PrincipalObj->Id);
        unless ($res) {
            $RT::Logger->warn("Failed to remove $username to $groupname: $msg");
        }
    }
}


=head2 _show_group

Show debugging information about the group record we're going to import
when the groups reruns us with C<--import>.

=cut

sub _show_group {
    my $self = shift;
    my %args = @_;
    my $group = $args{group};

    my $rt_group = RT::Group->new($RT::SystemUser);
    $rt_group->LoadUserDefinedGroup( $group->{Name} );

    if ( $rt_group->Id ) {
        $RT::Logger->debug( "Found existing group $group->{Name} to update" );
        $self->_show_group_info( %args, rt_group => $rt_group );
    } else {
        $RT::Logger->debug( "Found new group $group->{Name} to create in RT" );
        $self->_show_group_info( %args );
    }
}

sub _show_group_info {
    my $self = shift;
    my %args = @_;
    my $group = $args{group};
    my $rt_group = $args{rt_group};

    $RT::Logger->debug( "\tRT Field\tRT Value -> GWS Value" );
    foreach my $key (sort keys %$group) {
        my $old_value;
        if ($rt_group) {
            eval { $old_value = $rt_group->$key() };
            if ($group->{$key} && defined $old_value && $old_value eq $group->{$key}) {
                $old_value = 'unchanged';
            }
        }
        $old_value ||= 'unset';
        $RT::Logger->debug( "\t$key\t$old_value => $group->{$key}" );
    }
}


1;
