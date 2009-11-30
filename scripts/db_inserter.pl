#!/usr/bin/perl
#
# Copyright (C) 2007 Peteris Krumins (peter@catonmat.net)
# http://www.catonmat.net  -  good coders code, great reuse
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

use warnings;
use strict;

#
# This program was written as a part of "reddit media: intelligent fun online"
# website generator.
# This website can be viewed here: http://redditmedia.com 
#
# See http://www.catonmat.net/designing-reddit-media-website for more info.
#

#
# this script takes input in format:
#  title (type, url)
# and insert the title/url pairs in the sqlite database
#
# it is made to work with reddit_extractor.pl script but can be fed
# any input which is in that format
#

use DBI;
use POSIX;

use constant DATABASE_PATH => '/mnt/evms/services/apache/wwwroot/redditmedia/db/media.db';

my $dbh = DBI->connect("dbi:SQLite:" . DATABASE_PATH, '', '', { RaiseError => 1 });
die $DBI::errstr unless $dbh;

create_db_if_not_exists();

my $insert_query =<<EOL; 
INSERT OR IGNORE INTO reddit (title, url, type, reddit_id, user, date_added)
VALUES (?, ?, ?, ?, ?, ?)
EOL
my $sth = $dbh->prepare($insert_query);

while (<>) {
    next if /^#/;       # ignore comments
    my ($title, $type, $user, $rid, $url) = /(.+) \((\w+), (\w+), (\w+), (.+)\)/;
    next unless $url; # ignore erroneus lines
    
    $sth->execute($title, $url, $type, $rid, $user, strftime("%Y-%m-%d %H:%M:%S", localtime));
}

#
# if we do not  set $sth to undef, we get the following warning:
#
# DBI::db=HASH(0x1d287e8)->disconnect invalidates 1 active statement handle
# (either destroy statement handles or call finish on them before disconnecting)
# at db_inserter.pl line 65, <> line 4.
#
# closing dbh with active statement handles at db_inserter.pl line 65, <> line 4.
#
$sth = undef;

$dbh->disconnect;

#
# create_db_if_not_exists
#
# Creates reddit table if it does not exit
#
sub create_db_if_not_exists {
    # Older versions of sqlite 3 do not support IF NOT EXISTS clause,
    # we have to workaround
    #
    my $table_exists = 0;
    my $tables_q = "SELECT name FROM sqlite_master WHERE type='table' AND name='reddit'";
    my $res = $dbh->selectall_arrayref($tables_q);

    if (defined $res and @$res) {
        $table_exists = 1;
    }

    unless ($table_exists) {

        my $create_db =<<EOL;
CREATE TABLE reddit (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    title      STRING  NOT NULL    UNIQUE,
    url        STRING  NOT NULL    UNIQUE,
    reddit_id  STRING  NOT NULL    UNIQUE,
    user       STRING  NOT NULL,
    type       STRING  NOT NULL,
    date_added DATE    NOT NULL
)
EOL

        $dbh->do($create_db);
    }
}

