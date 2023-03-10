#!/usr/bin/perl -w
use strict;
use Data::Dumper;
use DBI;
use Error qw(:try);
use Getopt::Long;
use Git;
use Term::ANSIColor qw(colored);

my $db_file = 'git-fixes.db';
my $git_repo = '/home/latest/repos/suse/kernel-source';
my $db;

GetOptions(
	'db=s' => \$db_file,
	'git=s' => \$git_repo,
) or die("Error in command line arguments\n");

die "no $db_file" unless (-e $db_file);
die "no $git_repo" unless (-d "$git_repo/.git");

my $repo = Git->repository(Directory => $git_repo);

$db = DBI->connect("dbi:SQLite:dbname=$db_file", undef, undef,
	{AutoCommit => 0}) or
	die "connect to db error: " . DBI::errstr;

$db->do('PRAGMA foreign_keys = ON;') or
	die "cannot enable foreign keys";

sub do_prod(@) {
	my ($prod_id, $prod_name) = @_;

	print colored("=== $prod_name ===\n", "bright_green");

	my $sel = $db->prepare('SELECT fixes.id, shas.sha ' .
		'FROM fixes ' .
		'LEFT JOIN shas ON fixes.sha = shas.id ' .
		'WHERE fixes.prod = ? ' .
		'ORDER BY fixes.id;');

	$sel->execute($prod_id);

	my $del = $db->prepare('DELETE FROM fixes ' .
		'WHERE prod = ? AND ' .
		'fixes.sha = (SELECT id FROM shas WHERE sha = ?);');

	while (my $shas = $sel->fetchall_arrayref({ sha => 1 }, 300)) {
		last unless scalar @{$shas};

		my %git_commits;
		$shas = join('|', map { $$_{sha} } @{$shas});

		try {
			for my $line ($repo->command('grep', '-E',
					"Git-commit:\\s+($shas)",
					"origin/$prod_name", '--', 'patches.*')) {
				next unless ($line =~ /^[^:]+:([^:]+):Git-commit:\s+([0-9a-f]{12})/);
				$git_commits{$2} = $1;
			}
		} catch Git::Error::Command with {
			#print Dumper(shift), "\n";
		};

		try {
			for my $line ($repo->command('grep', '-E',
					"^($shas)",
					"origin/$prod_name", '--', 'blacklist.conf')) {
				next unless ($line =~ /^[^:]+:([^:]+):([0-9a-f]{12})/);
				$git_commits{$2} = $1;
			}
		} catch Git::Error::Command with {
			#print Dumper(shift), "\n";
		};

		next unless scalar %git_commits;
		#print Dumper(\%git_commits);

		for my $sha (keys %git_commits) {
			print colored("\tdropping $sha due to: ", 'yellow'),
				$git_commits{$sha}, "\n";
			print colored("\t\tdelete failed\n", "red")
				if ($del->execute($prod_id, $sha) != 1);
		}
	}
}

my @prods = @{$db->selectall_arrayref('SELECT id, prod FROM prod ORDER BY prod;')};
for my $prod (@prods) {
	do_prod(@{$prod});
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
