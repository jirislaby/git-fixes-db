#!/usr/bin/perl -w
use strict;
use DBI;
use Feature::Compat::Try;
use Getopt::Long;
use Git;
use Term::ANSIColor qw(colored);

my $db_file = 'git-fixes.db';
my $git_repo = $ENV{'KSOURCE_GIT'} // '/home/latest/repos/suse/kernel-source';
my $db;

GetOptions(
	'db=s' => \$db_file,
	'git=s' => \$git_repo,
) or die("Error in command line arguments\n");

die "no $db_file" unless (-e $db_file);

my $repo = Git->repository(Directory => $git_repo);

$db = DBI->connect("dbi:SQLite:dbname=$db_file", undef, undef,
	{AutoCommit => 0}) or
	die "connect to db error: " . DBI::errstr;

$db->do('PRAGMA foreign_keys = ON;') or
	die "cannot enable foreign keys";

sub do_branch(@) {
	my ($branch_id, $branch_name) = @_;

	print colored("=== $branch_name ===\n", "bright_green");

	my $sel = $db->prepare('SELECT fixes.id, shas.sha ' .
		'FROM fixes ' .
		'LEFT JOIN shas ON fixes.sha = shas.id ' .
		'WHERE fixes.branch = ? ' .
		'ORDER BY fixes.id;');

	$sel->execute($branch_id);

	my $del = $db->prepare('DELETE FROM fixes ' .
		'WHERE branch = ? AND ' .
		'fixes.sha = (SELECT id FROM shas WHERE sha = ?);');

	while (my $shas = $sel->fetchall_arrayref({ sha => 1 }, 300)) {
		last unless scalar @{$shas};

		my %git_commits;
		$shas = join('|', map { $$_{sha} } @{$shas});

		try {
			for my $line ($repo->command('grep', '-E',
					"Git-commit:\\s+($shas)",
					"origin/$branch_name", '--', 'patches.*')) {
				next unless ($line =~ /^[^:]+:([^:]+):Git-commit:\s+([0-9a-f]{12})/);
				$git_commits{$2} = $1;
			}
		} catch ($e) {
			#print Dumper($e), "\n";
		}

		try {
			for my $line ($repo->command('grep', '-E',
					"^($shas)",
					"origin/$branch_name", '--', 'blacklist.conf')) {
				next unless ($line =~ /^[^:]+:([^:]+):([0-9a-f]{12})/);
				$git_commits{$2} = $1;
			}
		} catch ($e) {
			#print Dumper($e), "\n";
		}

		next unless scalar %git_commits;
		#print Dumper(\%git_commits);

		for my $sha (keys %git_commits) {
			print colored("\tdropping $sha due to: ", 'yellow'),
				$git_commits{$sha}, "\n";
			print colored("\t\tdelete failed\n", "red")
				if ($del->execute($branch_id, $sha) != 1);
		}
	}
}

my @branches = @{$db->selectall_arrayref('SELECT id, branch FROM branch ORDER BY branch;')};
for my $branch (@branches) {
	do_branch(@{$branch});
}

my $rows = $db->do("DELETE FROM shas WHERE id NOT IN (SELECT sha FROM fixes);");
print "Dropped $rows shas\n" if ($rows > 0);
$rows = $db->do("DELETE FROM via WHERE id NOT IN (SELECT via FROM fixes WHERE via IS NOT NULL);");
print "Dropped $rows vias\n" if ($rows > 0);

END {
	print "\n";
	if (defined $db && $db->{Active}) {
		print "Committing\n";
		$db->commit;
		$db->disconnect;
	}
}

0;
