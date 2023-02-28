#!/usr/bin/perl -w
use strict;
use DBI;
use Getopt::Long;
use Git;
use Term::ANSIColor qw(colored);

my %blacklist = (
	qr@^(arch/x86/platform/olpc/|arch/x86/kernel/cpu/cyrix.c)@ => 'x86-32 unsupported',
);

my $oneline = 0;
my $db_file = 'git-fixes.db';
my $git_repo = '/home/latest/linux';
my $db;

GetOptions(
	'db=s' => \$db_file,
	'git=s' => \$git_repo,
	'oneline' => \$oneline,
) or die("Error in command line arguments\n");

die "no $db_file" unless (-e $db_file);
die "no $git_repo" unless (-d "$git_repo/.git");

my $repo = Git->repository(Directory => $git_repo);

$db = DBI->connect("dbi:SQLite:dbname=$db_file", undef, undef,
	{AutoCommit => 0}) or
	die "connect to db error: " . DBI::errstr;

$db->do('PRAGMA foreign_keys = ON;') or
	die "cannot enable foreign keys";

if (scalar @ARGV != 2) {
	my $sel = $db->prepare('SELECT COUNT(fixes.id) AS cnt, ' .
		'prod.prod, subsys.subsys ' .
		'FROM fixes ' .
			'JOIN prod ON fixes.prod = prod.id ' .
			'JOIN subsys ON fixes.subsys = subsys.id ' .
		'WHERE done != 1 ' .
		'GROUP BY fixes.prod, fixes.subsys ' .
		'HAVING cnt > 0 ' .
		'ORDER BY subsys.subsys, prod.prod;') or
		die "cannot prepare";
	$sel->execute();
	printf "%20s | %20s | %4s | COMMAND\n", "SUBSYS", "PRODUCT", "TODO";
	while (my $row = $sel->fetchrow_hashref) {
		printf "%20s | %20s | %4u | %s '%s' '%s'\n",
			$$row{subsys}, $$row{prod}, $$row{cnt},
			$0, $$row{subsys}, $$row{prod};
	}
	print "\n";
	die "bad args: $0 SUBSYS PRODUCT (from the above)";
}

my $subsys = shift @ARGV;
my $prod = shift @ARGV;

$SIG{INT} = sub { exit 1; };
$SIG{TERM} = sub { exit 1; };

my $sel = $db->prepare('SELECT fixes.id, fixes.sha, via.via ' .
	'FROM fixes LEFT JOIN via ON fixes.via = via.id ' .
	'WHERE fixes.subsys = (SELECT id FROM subsys WHERE subsys = ?) AND ' .
		'fixes.prod = (SELECT id FROM prod WHERE prod = ?) AND ' .
		'done != 1 ' .
	'ORDER BY fixes.id;');

$sel->execute($subsys, $prod);

sub do_oneline() {
	while (my $shas = $sel->fetchall_arrayref({ sha => 1 }, 500)) {
		last unless scalar @{$shas};
		$repo->command_noisy('show', '--color', '--oneline', '-s', map { $$_{sha} } @{$shas});
	}
}

sub match_blacklist($) {
	my ($sha) = @_;
	my $match;
	my @files = $repo->command('show', '--pretty=format:', '--name-only',
		$sha);
	for my $file (@files) {
		for my $bl (keys %blacklist) {
			if ($file =~ $bl) {
				return undef if (defined $match && $match != $blacklist{$bl});
				$match = $blacklist{$bl};
			}
		}
	}

	return $match;
}

sub do_walk() {
	my $up = $db->prepare('UPDATE fixes SET done = 1 WHERE id = ?');

	while (my $row = $sel->fetchrow_hashref) {
		my $sha = $$row{sha};
		my $via = $$row{via};

		system('clear');

		$sha = $repo->command_oneline('rev-parse', $sha);

		my $match = match_blacklist($sha);
		if (defined $match) {
			print colored("blacklist:\n", 'bright_green'), "$sha # $match\n";
		} else {
			$repo->command_noisy('show', '--color', $sha);

			if (defined $via) {
				print colored('VIA:', 'bright_green'), " $via\n";
			}
			print colored("blacklist:\n", 'bright_green'), "$sha # \n";
			print colored('susegen', 'bright_green'), " -r 'git-fixes' ~ -1 $sha\n";
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
	print "\n";
	if (defined $db && $db->{Active}) {
		print "Committing\n";
		$db->commit;
		$db->disconnect;
	}
}

0;
