#!/usr/bin/perl -w
use strict;
use DBI;
use Git;
use Term::ANSIColor qw(colored);

my $db_file = 'git-fixes.db';
my $git_repo = '/home/latest/linux';
my $db = undef;

die "bad args" unless (scalar @ARGV == 1);
die "no $db_file" unless (-e $db_file);
die "no $git_repo" unless (-d "$git_repo/.git");

my $prod = shift @ARGV;
my $repo = Git->repository(Directory => $git_repo);

$db = DBI->connect("dbi:SQLite:dbname=$db_file", undef, undef,
	{AutoCommit => 0}) or
	die "connect to db error: " . DBI::errstr;

my $sel = $db->prepare('SELECT id,sha FROM fixes WHERE prod=? AND done!=1 ' .
	'ORDER BY id');
my $up = $db->prepare('UPDATE fixes SET done=1 WHERE id=?');

$SIG{INT} = sub { exit 1; };
$SIG{TERM} = sub { exit 1; };

$sel->execute($prod);

while (my $row = $sel->fetchrow_hashref) {
	my $sha = $$row{sha};

	system('clear');

	$sha = $repo->command_oneline('rev-parse', $sha);

	$repo->command_noisy('show', '--color', $sha);

	print colored('blacklist:', 'bright_green'), " $sha # \n";
	print colored('susegen', 'bright_green'), " -r 'git-fixes' ~ -1 $sha\n";
	print colored('Mark as done? [y/N/q] ', 'bold bright_red');
	my $done = uc(<>);
	chomp($done);
	if ($done eq 'Y') {
		$up->execute($$row{id});
	} elsif ($done eq 'Q') {
		last;
	}
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
