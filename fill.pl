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

my @tables = (
	[ 'prod', 'id INTEGER PRIMARY KEY', 'prod TEXT NOT NULL UNIQUE' ],
	[ 'shas', 'id INTEGER PRIMARY KEY', 'sha TEXT NOT NULL UNIQUE' ],
	[ 'subsys', 'id INTEGER PRIMARY KEY', 'subsys TEXT NOT NULL UNIQUE' ],
	[ 'via', 'id INTEGER PRIMARY KEY', 'via TEXT NOT NULL UNIQUE' ],
	[ 'fixes', 'id INTEGER PRIMARY KEY',
		'sha INTEGER NOT NULL REFERENCES shas(id)',
		'done INTEGER DEFAULT 0 NOT NULL CHECK (done IN (0, 1))',
		'subsys INTEGER NOT NULL REFERENCES subsys(id)',
		'prod INTEGER NOT NULL REFERENCES prod(id)',
		'via INTEGER REFERENCES via(id)',
		q/created TEXT NOT NULL DEFAULT (datetime('now', 'localtime'))/,
		q/updated TEXT NOT NULL DEFAULT (datetime('now', 'localtime'))/,
		'UNIQUE(sha, prod)' ],
);

foreach my $entry (@tables) {
	my $name = shift @{$entry};
	my $desc = join ', ', @{$entry};
	$db->do("CREATE TABLE IF NOT EXISTS $name($desc) STRICT;") or
		die "cannot create table '$name'";
}

$db->do('CREATE INDEX IF NOT EXISTS fixes_done ON fixes(done);') or
	die "cannot create index fixes_done";
$db->do('CREATE TRIGGER IF NOT EXISTS fixes_updated ' .
	'AFTER UPDATE ON fixes ' .
	q/BEGIN UPDATE fixes SET updated=datetime('now', 'localtime') WHERE id=NEW.id; END;/) or
	die "cannot create trigger fixes_updated";
$db->do('CREATE VIEW IF NOT EXISTS fixes_expand AS ' .
	'SELECT fixes.id, fixes.done, subsys.subsys, prod.prod, shas.sha, ' .
		'via.via, fixes.created, fixes.updated ' .
	'FROM fixes ' .
	'LEFT JOIN subsys ON fixes.subsys = subsys.id ' .
	'LEFT JOIN prod ON fixes.prod = prod.id ' .
	'LEFT JOIN shas ON fixes.sha = shas.id ' .
	'LEFT JOIN via ON fixes.via = via.id;') or
	die "cannot create VIEW fixes_expand";
$db->do('CREATE VIEW IF NOT EXISTS fixes_expand_sorted AS ' .
	'SELECT * FROM fixes_expand ' .
	'ORDER BY subsys, prod, id;') or
	die "cannot create VIEW fixes_expand_sorted";

for my $file (@ARGV) {
	my $subsys;

	open(my $fh, "<", $file) or die "cannot open $file";

	while (<$fh>) {
		s/\R//;
		last if /^={10,}/;
		$subsys = $1 if (/^Subject: .* Pending Fixes(?: Update)? for (.*)$/);
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
			last unless /^\s+Considered for (\S+)(?: (?:via|as fix for) (.+))?$/;
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
