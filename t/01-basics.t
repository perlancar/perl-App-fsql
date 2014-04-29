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

subtest "option --add" => sub {
    write_file("$tmpdir/t901", "c1,c2\n1,2\n");
    write_file("$tmpdir/t902", "c1\tc2\n1\t2\n");
    write_file("$tmpdir/t903", "c1:1\tc2:2\n");
    write_file("$tmpdir/t904", '[{"c1":1,"c2":2}]');
    write_file("$tmpdir/t905", "[[foo, bar]]\n");
    write_file("$tmpdir/t906", "[{c1=>1, c2=>2}]");

    test_fsql(
        argv     => [
            "-a", "$Bin/data/1.csv:t1",
            "-a", "$Bin/data/1.tsv:t2",
            "-a", "$Bin/data/1.ltsv:t3",
            "-a", "$Bin/data/1.json:t4",
            "-a", "$Bin/data/1.yaml:t5",
            "-a", "$Bin/data/1.pl:t6",

            # test autodetect
            "-a", "$tmpdir/t901",
            "-a", "$tmpdir/t902",
            "-a", "$tmpdir/t903",
            "-a", "$tmpdir/t904",
            "-a", "$tmpdir/t905",
            "-a", "$tmpdir/t906",

            "--show-schema", "-f", "perl",
        ],
        posttest => sub {
            my $res = shift;
            my $envres = eval $res->{stdout};

            is($envres->[2]{tables}{t1}{fmt}, 'csv');
            is($envres->[2]{tables}{t2}{fmt}, 'tsv');
            is($envres->[2]{tables}{t3}{fmt}, 'ltsv');
            is($envres->[2]{tables}{t4}{fmt}, 'json');
            is($envres->[2]{tables}{t5}{fmt}, 'yaml');
            is($envres->[2]{tables}{t6}{fmt}, 'perl');

            is($envres->[2]{tables}{t901}{fmt}, 'csv');
            is($envres->[2]{tables}{t902}{fmt}, 'tsv');
            is($envres->[2]{tables}{t903}{fmt}, 'ltsv');
            is($envres->[2]{tables}{t904}{fmt}, 'json');
            is($envres->[2]{tables}{t905}{fmt}, 'yaml');
            is($envres->[2]{tables}{t906}{fmt}, 'perl');

            is($envres->[2]{tables}{t1}{fmt}, 'csv');
            is($envres->[2]{tables}{t1}{fmt}, 'csv');
        },
    );

    # XXX test can't autodetect

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

subtest "option --show-schema" => sub {
    test_fsql(
        argv     => ["--add-yaml", "$Bin/data/1.yaml:t1", "--add-perl", "$Bin/data/1.pl:t2", "--show-schema", "-f", "perl"],
        posttest => sub {
            my $res = shift;
            my $envres = eval($res->{stdout});
            ok($envres->[2]{tables}{t1});
            ok($envres->[2]{tables}{t2});
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
