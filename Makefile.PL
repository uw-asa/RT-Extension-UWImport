use inc::Module::Install;

RTx     'RT-Extension-UWImport';
license 'gpl_2';
repository 'https://github.com/uw-it-cte/rt-extension-uwimport';

requires_rt '4.2.0';
rt_too_new '4.6.0';

my ($lib_path) = $INC{'RT.pm'} =~ /^(.*)[\\\/]/;
my $local_lib_path = "$RT::LocalPath/lib";

# Straight from perldoc perlvar
use Config;
my $secure_perl_path = $Config{perlpath};
if ($^O ne 'VMS') {
    $secure_perl_path .= $Config{_exe}
        unless $secure_perl_path =~ m/$Config{_exe}$/i;
}

substitute( {
        RT_LIB_PATH => $lib_path,
        LOCAL_LIB_PATH => $local_lib_path,
        PERL         => $ENV{PERL} || $secure_perl_path,
    },
    {
        sufix => '.in'
    },
    qw(bin/rt-uwimport),
);

sign;
WriteAll;
