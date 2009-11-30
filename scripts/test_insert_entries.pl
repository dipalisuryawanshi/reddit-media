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
#

#
# This program was written as a part of "reddit media: intelligent fun online"
# website generator.
# This website can be viewed here: http://redditmedia.com 
#
# See http://www.catonmat.net/designing-reddit-media-website for more info.
#

use DBI;
use POSIX;
use constant DATABASE_PATH   => '/mnt/evms/services/apache/wwwroot/redditmedia/db/media.db';

my $insert = shift || 1;
my $type   = shift || 'rand';

my $dbh = DBI->connect("dbi:SQLite:" . DATABASE_PATH, '', '', { RaiseError => 1 });
die $DBI::errstr unless $dbh;

while ($insert--) {
    my $rc = rand_crap();
    my $rt = rand_type();
    my $now = strftime("%Y-%m-%d %H:%M:%S", localtime);
    my $q = "
INSERT INTO reddit (title, url, reddit_id, user, type, date_added)
VALUES ('$rc', '$rc', '$rc', '$rc', '$rt', '$now')
";

    $dbh->do($q);
}

sub rand_crap {
    my @az = ("a".."z");
    return join '', map { $az[rand @az] } 1..10;
}

sub rand_type {
    if ($type eq "rand") {
        my @types = ('video', 'videos', 'picture', 'pictures');
        return $types[rand @types];
    }
    return $type;
}
