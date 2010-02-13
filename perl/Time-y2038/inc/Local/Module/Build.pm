package Local::Module::Build;

use strict;
use base qw(Module::Build);

use ExtUtils::CBuilder;
use JSON::XS;

sub probe_system_time {
    my $self = shift;
    $self->note_time_limits;
    $self->note_time_capabilities;
}

sub note_time_capabilities {
    my $self = shift;

    my %tests = (
        HAS_TIMEGM      => <<'END',
    struct tm *date;
    time_t zero;

    date = localtime(&zero);
    zero = timegm(date);
END

        HAS_GMTIME_R    => <<'END',
    struct tm date;
    time_t zero = 0;
    (void)gmtime_r(&zero, &date);
END

        HAS_LOCALTIME_R => <<'END',
    struct tm date;
    time_t zero = 0;
    (void)localtime_r(&zero, &date);
END

        HAS_TM_TM_GMTOFF => <<'END',
    struct tm *date;
    time_t zero;
    int offset;

    date = gmtime(&zero);
    offset = date->tm_gmtoff;
END

        HAS_TM_TM_ZONE => <<'END',
    struct tm *date;
    time_t zero;
    char *zone;

    date = gmtime(&zero);
    zone = date->tm_zone;
END
    );

    my $cb = ExtUtils::CBuilder->new( quiet => 1 );
    for my $test (keys %tests) {
        my $code = $tests{$test};

        $code = <<END;
#include <time.h>

int main() {
$code

    return 0;
}
END

        open my $fh, ">", "try.c" or die "Can't write try.c: $!";
        print $fh $code;
        close $fh;

        my $obj = eval { $cb->compile(source => "try.c"); };
        $self->notes($test, $obj ? 1 : 0);
        unlink $obj if $obj;
        unlink "try.c";
    }
}


sub note_time_limits {
    my $self = shift;

    my $source = "check_max.c";
    my $exe    = $self->notes("check_max") || "check_max";
    unless( $self->up_to_date($source => $exe) ) {
        warn "Building a program to test the range of your system time functions...\n";
        my $cb = $self->cbuilder;
        my $obj = $cb->compile(source => "check_max.c", include_dirs => ['y2038']);
        $exe = $cb->link_executable(objects => $obj, exe_file => $exe);
        $exe = $self->find_real_exe($exe);
        $self->notes(check_max => $exe);
        $self->add_to_cleanup($exe);
    }

    return if $self->up_to_date(["y2038/time64_config.h.in", "munge_config", $exe]
                                => "y2038/time64_config.h");
    warn "  and running it...\n";

    my $json = `./$exe`;
    $json =~ s{^\#.*\n}{}gm;
    my $limits = decode_json($json);

    warn "  Done.\n";

    my %config;
    for my $key (qw(gmtime localtime)) {
        for my $limit (qw(min max)) {
            $config{$key."_".$limit} = $limits->{$key}{$limit};
        }
    }

    for my $key (qw(mktime timegm)) {
        for my $limit (qw(min max)) {
            my $struct = $limits->{$key}{$limit};
            for my $tm (keys %$struct) {
                $config{$key."_".$limit."_".$tm} = $struct->{$tm};
            }
        }
    }

    # Windows lies about being able to handle just a little bit of
    # negative time.
    for my $key (qw(gmtime_min localtime_min)) {
        if( -10_000 < $config{$key} && $config{$key} < 0 ) {
            $config{$key} = 0;
        }
    }

    for my $key (sort { $a cmp $b } keys %config) {
        my $val = $config{$key};
        warn sprintf "%15s:  %s\n", $key, $val;
        $self->notes($key, "$val");
    }

    return;
}


# This is necessary because Cygwin nerotically puts a .exe on
# every executable.  This appears to be built into gcc.
sub find_real_exe {
    my $self = shift;
    my $exe = shift;

    my $real_exe;
    for ($exe, "$exe.exe") {
        $real_exe = $_ if -e;
    }

    warn "Can't find the executable, thought it was $exe"
        unless defined $real_exe;

    return $real_exe;
}


sub ACTION_code {
    my $self = shift;

    $self->probe_system_time;

    return $self->SUPER::ACTION_code(@_);
}

1;

