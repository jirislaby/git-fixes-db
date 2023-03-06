#!/usr/bin/perl -w
use strict;
use DBI qw(:sql_types);
use Getopt::Long;
use Term::ANSIColor qw(colored);

my $db_file = 'git-fixes.db';
my $db;

GetOptions(
	'db=s' => \$db_file,
) or die("Error in command line arguments\n");

$db = DBI->connect("dbi:SQLite:dbname=$db_file", undef, undef,
	{AutoCommit => 0}) or
	die "connect to db error: " . DBI::errstr;

$db->do('PRAGMA foreign_keys = ON;') or
	die "cannot enable foreign keys";

$db->do('CREATE TABLE IF NOT EXISTS prod(id INTEGER PRIMARY KEY, ' .
	'prod TEXT NOT NULL UNIQUE) STRICT;') or
	die "cannot create table fixes";
$db->do('CREATE TABLE IF NOT EXISTS shas(id INTEGER PRIMARY KEY, ' .
	'sha TEXT NOT NULL UNIQUE) STRICT; ') or
	die "cannot create table shas";
$db->do('CREATE TABLE IF NOT EXISTS subsys(id INTEGER PRIMARY KEY, ' .
	'subsys TEXT NOT NULL UNIQUE) STRICT;') or
	die "cannot create table subsys";
$db->do('CREATE TABLE IF NOT EXISTS via(id INTEGER PRIMARY KEY, ' .
	'via TEXT NOT NULL UNIQUE) STRICT;') or
	die "cannot create table via";
$db->do('CREATE TABLE IF NOT EXISTS fixes(id INTEGER PRIMARY KEY, ' .
	'sha INTEGER NOT NULL REFERENCES shas(id), ' .
	'done INTEGER DEFAULT 0 NOT NULL, ' .
	'subsys INTEGER NOT NULL REFERENCES subsys(id), ' .
	'prod INTEGER NOT NULL REFERENCES prod(id), ' .
	'via INTEGER REFERENCES via(id), ' .
	'UNIQUE(sha, prod)) STRICT;') or
	die "cannot create table fixes";

for my $file (@ARGV) {
	my $subsys;

	open(my $fh, "<", $file) or die "cannot open $file";

	while (<$fh>) {
		s/\R//;
		last if /^={10,}/;
		$subsys = $1 if (/^Subject: .* Pending Fixes for (.*)$/);
	}

	die "no subsystem in $file?" unless defined $subsys;

	print colored("\n==== $subsys ====\n", "bright_green");

	my $ins = $db->prepare('INSERT OR IGNORE INTO subsys(subsys) VALUES (?);') or
		die "cannot prepare subsys";

	$ins->execute($subsys);

	$ins = $db->prepare('INSERT INTO fixes(sha, via, subsys, prod) ' .
		'SELECT shas.id, via.id, subsys.id, prod.id FROM shas, prod, subsys ' .
		'LEFT JOIN via ON via.via=? ' .
		'WHERE shas.sha=? AND subsys.subsys=? AND prod.prod=?;') or
		die "cannot prepare fixes";
	$ins->{PrintError} = 0;
	my $ins_prod = $db->prepare('INSERT OR IGNORE INTO prod(prod) VALUES (?);') or
		die "cannot prepare prod";
	my $ins_sha = $db->prepare('INSERT OR IGNORE INTO shas(sha) VALUES (?);') or
		die "cannot prepare sha";
	my $ins_via = $db->prepare('INSERT OR IGNORE INTO via(via) VALUES (?);') or
		die "cannot prepare via";

	while (<$fh>) {
		s/\R//;
		next unless /^([a-f0-9]{12})/;
		my $sha = $1;
		print "sha=$sha\n";
		$ins_sha->execute($sha);

		while (<$fh>) {
			s/\R//;
			last unless /^\s+Considered for (\S+)(?: (?:via|as fix for) (\S+))?/;
			my $prod = $1;
			my $via = $2;

			$ins_prod->execute($prod);
			$ins_via->execute($via) if (defined $via);

			print "\tprod=$prod\n";
			if (!$ins->execute($via, $sha, $subsys, $prod)) {
				die "cannot insert: " . $ins->errstr
					if ($ins->errstr !~ /UNIQUE constraint failed/);
				print colored("\t\tskipped a dup\n", "yellow")
			}
		}
	}
	close $fh;
}

END {
	if (defined $db && $db->{Active}) {
		$db->commit;
		$db->disconnect;
	}
}

0;
