#!/usr/bin/perl -w
use strict;
use DBI qw(:sql_types);

my $db_file = 'git-fixes.db';
my $do_create = !-e $db_file;
my $db = DBI->connect("dbi:SQLite:dbname=$db_file", undef, undef,
	{AutoCommit => 0}) or
	die "connect to db error: " . DBI::errstr;

if ($do_create) {
	print "Creating table\n";
	$db->do('CREATE TABLE fixes(id INTEGER PRIMARY KEY, ' .
		'sha TEXT NOT NULL, prod TEXT NOT NULL, '.
		'via TEXT, done INTEGER DEFAULT 0 NOT NULL, ' .
		'unique(sha, prod)) STRICT;') or
		die "cannot create table";
}

while (<>) {
	last if /^={10,}/;
}

my $ins = $db->prepare('INSERT INTO fixes(sha, prod, via)' .
	'VALUES (?, ?, ?)') or die "cannot prepare";

# make sure the data are a string

while (<>) {
	s/\R//;
	next unless /^([a-f0-9]{12})/;
	my $sha = $1;
	print "sha=$sha\n";

	while (<>) {
		s/\R//;
		last unless /^\s+Considered for (\S+)(?: via (\S+))?/;
		my $prod = $1;
		my $via = $2;

		print "\tprod=$prod\n";
		$ins->execute($sha, $prod, $via);
	}
}

END {
	if (defined $db && $db->{Active}) {
		$db->commit;
		$db->disconnect;
	}
}

0;
