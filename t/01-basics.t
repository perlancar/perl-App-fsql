#!perl

use 5.010;
use strict;
use warnings;
use FindBin '$Bin';

use File::chdir;
use File::Slurp;
use File::Temp qw(tempdir);
use IPC::Cmd qw(run_forked);
use String::ShellQuote;
use Test::More 0.98;

BEGIN {
    if ($^O =~ /win/i) {
        plan skip_all => "run_forked() not available on Windows";
        exit 0;
    }
}

sub lines { join("", map {"$_\n"} @_) }

my ($tmpdir) = tempdir(CLEANUP => 1);
$CWD = $tmpdir;

subtest "option --add-csv" => sub {
    test_fsql(
        argv     => ["--add-csv", "$Bin/data/1.csv:t", q(SELECT col1 FROM t WHERE col__2 <= 2)],
        output   => lines("col1","a","b"),
    );
};
subtest "option --add-tsv" => sub {
    test_fsql(
        argv     => ["--add-tsv", "$Bin/data/1.tsv:t", q(SELECT col1 FROM t WHERE col__2 <= 2)],
        output   => lines("col1","a","b"),
    );
};
subtest "option --add-ltsv" => sub {
    test_fsql(
        argv     => ["--add-ltsv", "$Bin/data/1.ltsv:t", q(SELECT col1 FROM t WHERE col__2 <= 2)],
        output   => lines("col1:a","col1:b"),
    );
};
subtest "option --add-json" => sub {
    test_fsql(
        argv     => ["--add-json", "$Bin/data/1.json:t", q(SELECT col1 FROM t WHERE col__2 <= 2)],
        posttest => sub {
            require JSON;

            my $res = shift;
            is_deeply(JSON->new->decode($res->{stdout}),
                      [200,"OK",[["a"],["b"]],{"table.fields"=>["col1"]}]);
        },
    );
};
subtest "option --add-yaml" => sub {
    test_fsql(
        argv     => ["--add-yaml", "$Bin/data/1.yaml:t", q(SELECT col1 FROM t WHERE col__2 <= 2)],
        posttest => sub {
            require YAML::XS;

            my $res = shift;
            is_deeply(YAML::XS::Load($res->{stdout}),
                      [200,"OK",[["a"],["b"]],{"table.fields"=>["col1"]}]);
        },
    );
};
subtest "option --add-perl" => sub {
    test_fsql(
        argv     => ["--add-perl", "$Bin/data/1.pl:t", q(SELECT col1 FROM t WHERE col__2 <= 2)],
        posttest => sub {
            my $res = shift;
            is_deeply(eval($res->{stdout}),
                      [200,"OK",[["a"],["b"]],{"table.fields"=>["col1"]}]);
        },
    );
};

subtest "option --hash" => sub {
    test_fsql(
        argv     => ["--hash", "--add-perl", "$Bin/data/1.pl:t", q(SELECT col1 FROM t WHERE col__2 <= 2)],
        posttest => sub {
            my $res = shift;
            is_deeply(eval($res->{stdout}),
                      [200,"OK",[{col1=>"a"},{col1=>"b"}],{"table.fields"=>["col1"]}]);
        },
    );
};

DONE_TESTING:
done_testing;
if (Test::More->builder->is_passing) {
    diag "all tests successful, deleting test data dir";
    $CWD = "/";
} else {
    diag "there are failing tests, not deleting test data dir $tmpdir";
}

sub test_fsql {
    my %args = @_;

    my @progargs = @{ $args{argv} // [] };
    my $name = $args{name} // join(" ", @progargs);
    subtest $name => sub {
        my $expected_exit = $args{exitcode} // 0;
        my %runopts;
        $runopts{child_stdin} = $args{input} if defined $args{input};
        # run_forked() doesn't accept arrayref command, lame
        my $cmd = join(
            " ",
            map {shell_quote($_)}
                ($^X, "$FindBin::Bin/../bin/fsql", @progargs));
        note "cmd: $cmd";
        my $res = run_forked($cmd, \%runopts);

        is($res->{exit_code}, $expected_exit,
           "exit code = $expected_exit") or do {
               if ($expected_exit == 0) {
                   diag explain $res;
               }
           };

        # convert line ending
        for ($res->{stdout}) {
            s/\r//g;
        }

        if (defined $args{output}) {
            is($res->{stdout}, $args{output}, "output");
        }

        if ($args{posttest}) {
            $args{posttest}->($res);
        }
    };
}
