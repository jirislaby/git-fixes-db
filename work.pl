#!/usr/bin/perl -w
use strict;
use DBI;
use Feature::Compat::Try;
use File::Basename qw(fileparse);
use File::HomeDir;
use Getopt::Long;
use Git;
use Pod::Usage qw(pod2usage);
use Term::ANSIColor qw(colored);

my $oneline = 0;
my $db_file = 'git-fixes.db';
my $cfm_db_file = File::HomeDir->my_home . '/.cache/suse-get-maintainers/conf_file_map.sqlite';
my $git_linux = $ENV{'LINUX_GIT'};
my $git_ks = $ENV{'KSOURCE_GIT'};
my $git_stable_q = $ENV{'STABLE_QUEUE_GIT'};
my $db;
my $cfm_db;

GetOptions(
	'db=s' => \$db_file,
	'cfm-db=s' => \$cfm_db_file,
	'git-linux=s' => \$git_linux,
	'git-kernel-source=s' => \$git_ks,
	'git-stable-queue=s' => \$git_stable_q,
	'oneline' => \$oneline,
) or pod2usage(2);

die "no $db_file" unless (-e $db_file);
die "no $cfm_db_file" unless (-e $cfm_db_file);
die "old $cfm_db_file" if (-M $cfm_db_file > 7);

my $repo_linux = Git->repository(Directory => $git_linux);
my $repo_ks = Git->repository(Directory => $git_ks);
my $repo_stable_q = Git->repository(Directory => $git_stable_q);

sub open_db($$) {
	my ($db_file, $ro) = @_;

	my $db = DBI->connect("dbi:SQLite:dbname=$db_file", undef, undef,
		{AutoCommit => 0, ReadOnly => $ro}) or
		die "connect to db error: " . DBI::errstr;

	$db->do('PRAGMA foreign_keys = ON;') or
		die "cannot enable foreign keys";

	return $db;
}

$db = open_db($db_file, 0);
$cfm_db = open_db($cfm_db_file, 1);

if (scalar @ARGV != 2) {
	my $sel = $db->prepare('SELECT COUNT(fixes.id) AS cnt, ' .
		'branch.branch, subsys.subsys ' .
		'FROM fixes ' .
			'JOIN branch ON fixes.branch = branch.id ' .
			'JOIN subsys ON fixes.subsys = subsys.id ' .
		'WHERE done = 0 ' .
		'GROUP BY fixes.branch, fixes.subsys ' .
		'HAVING cnt > 0 ' .
		'ORDER BY subsys.subsys, branch.branch;') or
		die "cannot prepare";
	$sel->execute();
	printf "%30s | %20s | %4s | COMMAND\n", "SUBSYS", "PRODUCT", "TODO";
	while (my $row = $sel->fetchrow_hashref) {
		printf "%30s | %20s | %4u | %s '%s' '%s'\n",
			$$row{subsys}, $$row{branch}, $$row{cnt},
			$0, $$row{subsys}, $$row{branch};
	}
	print "\n";
	pod2usage(1);
}

my $subsys = shift @ARGV;
my $branch = shift @ARGV;

$SIG{INT} = sub { exit 1; };
$SIG{TERM} = sub { exit 1; };

my $sel = $db->prepare('SELECT fixes.id, shas.sha, via.via ' .
	'FROM fixes ' .
	'LEFT JOIN via ON fixes.via = via.id ' .
	'LEFT JOIN shas ON fixes.sha = shas.id ' .
	'WHERE fixes.subsys = (SELECT id FROM subsys WHERE subsys = ?) AND ' .
		'fixes.branch = (SELECT id FROM branch WHERE branch = ?) AND ' .
		'done = 0 ' .
	'ORDER BY fixes.id;') or die "cannot prepare";

my $sel_sha = $db->prepare('SELECT 1 ' .
	'FROM fixes ' .
	'WHERE sha = (SELECT id FROM shas WHERE sha LIKE ?) AND ' .
		'branch = (SELECT id FROM branch WHERE branch = ?);') or
	die "cannot prepare";

my $cfm_sel = $cfm_db->prepare('SELECT config.config ' .
	'FROM conf_file_map AS map ' .
	'LEFT JOIN config ON map.config = config.id ' .
	'WHERE branch = (SELECT id FROM branch WHERE branch = ?) ' .
	'AND map.file = (SELECT id FROM file WHERE file = ? ' .
		'AND dir = (SELECT id FROM dir WHERE dir = ?));') or
	die "cannot prepare";

$sel->execute($subsys, $branch);

sub do_oneline() {
	while (my $shas = $sel->fetchall_arrayref({ sha => 1 }, 500)) {
		last unless scalar @{$shas};
		$repo_linux->command_noisy('show', '--color', '--oneline', '-s', map { $$_{sha} } @{$shas});
	}
}

sub match_blacklist($$$) {
	my ($branch, $sha, $confs) = @_;
	my $match;
	my @files = $repo_linux->command('show', '--pretty=format:', '--name-only', $sha);

	for my $file (@files) {
		my $file_match;
		my ($filename, $dir) = fileparse($file);
		$dir =~ s|/$||;

		$cfm_sel->execute($branch, $filename, $dir);
		my @config = $cfm_sel->fetchrow_array;
		$cfm_sel->finish;

		if (@config) {
			try {
				push @{$confs}, map { s/^[^:]+://; $_ }
					$repo_ks->command('grep', '-E', $config[0] . '=', "origin/$branch",
					'--', 'config');
			} catch ($e) {
				my $eq_n = $config[0] . '=n';
				# matches different bl entries -- suspicious
				return undef if (defined $file_match && $file_match ne $eq_n);
				$file_match = $eq_n;
			}
		}

		# only some of the files match -- don't skip
		return undef if (defined $match && !defined $file_match);

		$match = $file_match;
	}

	return $match;
}

sub check_deps($$$$) {
	my ($branch, $sha, $via, $deps) = @_;

	return undef unless ($via);

	if (my ($stable_ver) = $via =~ /Stable-([0-9.]+)$/) {
		try {
			my @patches = $repo_stable_q->command('grep', '-l', $sha,
				'--', "queue-$stable_ver/", "releases/$stable_ver.*");
			@{$deps} = $repo_stable_q->command('grep', '-h', 'Stable-dep-of',
				'--', @patches);
		} catch ($e) {
			return undef;
		}
		if (my ($dep) = $$deps[0] =~ /Stable-dep-of:\s*([0-9a-f]+)/) {
			$sel_sha->execute("$dep%", $branch);

			my $ref = $sel_sha->fetchrow_arrayref;
			$sel_sha->finish;
			if (!$ref) {
				try {
					$repo_ks->command('grep', $dep, "origin/$branch", '--',
						'patches.suse/', 'blacklist.conf');
				} catch ($e) {
					return "Stable-dep-of: $dep not included";
				}
			}
		}
	}

	return undef;
}

sub should_blacklist($$$$$) {
	my ($branch, $sha, $via, $confs, $deps) = @_;

	my $match = match_blacklist($branch, $sha, $confs);
	return $match if ($match);

	return check_deps($branch, $sha, $via, $deps);
}

sub gde($) {
	my $sha = shift;

	try {
		my $gde = $repo_linux->command_oneline([ 'describe', '--contains',
			'--exact-match', $sha ], { STDERR => 0 });
		$gde //= colored("SHA $sha not known", 'red');
		$gde =~ s/~.*//;

		return $gde;
	} catch ($e) {
		return "no tag yet";
	}
}

sub do_walk() {
	my $up = $db->prepare('UPDATE fixes SET done = 1 WHERE id = ?');

	while (my $row = $sel->fetchrow_hashref) {
		my $sha = $$row{sha};
		my $via = $$row{via};

		system('clear');

		git_cmd_try {
			$sha = $repo_linux->command_oneline('rev-parse', $sha);
		} "cannot find sha '$sha' in your tree";

		my @confs;
		my @deps;
		my $match = should_blacklist($branch, $sha, $via, \@confs, \@deps);
		if (defined $match) {
			print colored("blacklist:\n", 'bright_green'), "$sha # $match\n";
		} else {
			$repo_linux->command_noisy('show', '--color', $sha);

			print colored("Configs:\n", 'bright_green') if (@confs);
			foreach my $conf (@confs) {
				print "\t$conf\n";
			}
			print colored('Present in:', 'bright_green'), " ", gde($sha), "\n";
			my @fixes = $repo_linux->command('show', '--pretty=format:%b', '-s', $sha);
			@fixes = map { /(?:[Ff]ixes:|[Cc][Cc]:.*stable.*#)\s+([0-9a-fA-F]{6,})/ ? ($1) : () } @fixes;
			foreach my $f (@fixes) {
				print colored('Fixes:', 'bright_green'), " $f (", gde($f), "):\n";
				print "git grep $f\n";
			}

			if (defined $via) {
				print colored('VIA:', 'bright_green'), " $via\n";
				foreach my $dep (@deps) {
					print "\t$dep\n";
				}
			}
			print colored("blacklist:\n", 'bright_green'), "$sha # \n";
			print colored('susegen', 'bright_green'), " -r 'git-fixes' ~ -1 $sha\n";
			print colored('exportpatch', 'bright_green'), " -fwsnd ~ -F 'git-fixes' $sha\n";
		}

		print colored('Mark as done? [y/N/q] ', 'bold bright_red');
		my $done = uc(<>);
		chomp($done);
		if ($done eq 'Y') {
			$up->execute($$row{id});
		} elsif ($done eq 'Q') {
			$sel->finish;
			last;
		}
	}
}

if ($oneline) {
	do_oneline();
} else {
	do_walk();
}

END {
	sub finish_db($) {
		my $db = shift;
		if (defined $db && $db->{Active}) {
			$db->commit;
			$db->disconnect;
		}
	}

	finish_db($db);
	finish_db($cfm_db);
}

1;

__END__

=head1 SYNOPSIS

work.pl [options] [subsys branch]

 Options:
   --db=file		database to read from [default=git-fixes.db]
   --cfm-db=file	database with conf_file_map [default=conf_file_map.sqlite]
   --git-linux		linux git repo [default=ENV{LINUX_GIT}]
   --git-kernel-source	kernel-source git repo [default=ENV{KSOURCE_GIT}]
   --git-stable-queue	stable-queue git repo [default=ENV{STABLE_QUEUE_GIT}]
   --oneline		print all TODO commits, one per line
