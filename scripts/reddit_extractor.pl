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

use LWP::UserAgent;
use HTML::TreeBuilder;
use HTML::Entities;
use URI;

#
# This script accesses reddit.com website and goes through all the pages
# it can find, looking for link titles matching patterns specified
# in %extract_patterns hash or domains specified in %extract_domains hash.
#

use constant VOTE_THRESHOLD => 10; # include only titles with at least this
                                   # much votes

# These regex patterns match common picture and video reddit titles
# notice the order of plural and singular.
my @extract_patterns = (
    # pattern                  type
    "[[(].*pictures.*[])]" => 'pictures',
    "[[(].*picture.*[])]"  => 'picture',
    "[[(].*pics.*[])]"     => 'pictures',
    "[[(].*pic.*[])]"      => 'picture',
    "[[(].*images.*[])]"   => 'pictures',
    "[[(].*image.*[])]"    => 'picture',
    "[[(].*photos.*[])]"   => 'pictures',
    "[[(].*photo.*[])]"    => 'picture',
    "[[(].*comics.*[])]"   => 'pictures',
    "[[(].*comic.*[])]"    => 'picture',
    "[[(].*charts.*[])]"   => 'pictures',
    "[[(].*chart.*[])]"    => 'picture',
    "[[(].*vids.*[])]"     => 'videos',
    "[[(].*vid.*[])]"      => 'video',
    "[[(].*videos.*[])]"   => 'videos',
    "[[(].*video.*[])]"    => 'video',
    "[[(].*clips.*[])]"    => 'videos',
    "[[(].*clip.*[])]"     => 'video',
    "[[(].*films.*[])]"    => 'videos',
    "[[(].*film.*[])]"     => 'video',
    "[[(].*movies.*[])]"   => 'videos',
    "[[(].*movie.*[])]"    => 'video'
);

# These regex patterns match domains which usually contain only images
# and videos.
my @extract_domains = (
    # video sites
    'youtube.com'           => 'video',
    'video.google.com'      => 'video',
    'liveleak.com'          => 'video',
    'break.com'             => 'video',
    'metacafe.com'          => 'video',
    'brightcove.com'        => 'video', 
    'dailymotion.com'       => 'video',
    'dailymotion.alice.it'  => 'video',
    'flicklife.com'         => 'video',
    'flixya.com'            => 'video',
    'flurl.com'             => 'video',
    'gofish.com'            => 'video',
    'ifilm.com'             => 'video',
    'livevideo.com'         => 'video',
    'video.yahoo.com'       => 'video',

    # image sites
    'photobucket.com'       => 'picture',
    'photo.livevideo.com'   => 'picture',
    'flickr.com'            => 'picture',
    'xkcd.com'              => 'picture'
);

# compile regex extract pattern
#my $joined_patterns = join '|', @extract_patterns;
#my $c_extract_patterns = qr{$joined_patterns}i;

# compile regex extract pattern
#$joined_patterns = join '|', @extract_domains;
#my $c_extract_domains = qr{$joined_patterns}i;

my $pages_to_get = shift || 'all';

# exit successfully if we do not want any pages to be parsed
exit 0 unless $pages_to_get;

my $ua = LWP::UserAgent->new(
    agent => 'Mozilla/5.0 (Windows; U; Windows NT 5.1; en-US) Gecko/20070515 Firefox/2.0.0.4'
);
my $reddit_page = get_page($ua, 'http://reddit.com');

extract_and_print($reddit_page);
$pages_to_get-- if $pages_to_get =~ /\d+/;

my $next_page;
if ($pages_to_get eq 'all') {
    while ($next_page = get_next_page_url($reddit_page)) {
        $reddit_page = get_page($ua, $next_page);
        extract_and_print($reddit_page);
    }
}
else {
    while ($pages_to_get--) {
        $next_page = get_next_page_url($reddit_page);
        $reddit_page = get_page($ua, $next_page);
        extract_and_print($reddit_page);
    }
}

#
# get_page
#
# Given an URL, the subroutine returns content of the resource located at URL.
# die()s if getting the URL fails
#
sub get_page {
    my ($ua, $url) = @_;

    my $response = $ua->get($url);
    unless ($response->is_success) {
        die "Failed getting $url: ", $response->status_line;
    }

    return $response->content;
}

#
# extract_and_print
#
# Subroutine takes html content and extracts reddit links, titles and domains
# from the content. Then it tests each title and domain against
# extract patterns (both domain and title). If matched, it will
# print a human readable output in format:
#
# title (type, user, reddit id, url)
#
# The output is used by a script which imports it into sqlite database.
#
sub extract_and_print {
    my $content = shift or
        die "Error: no content provided to extract_and_print";

    my @posts = extract_posts($content);
    my @to_print;

    POST:
    foreach my $post (@posts) { # naive algorithm, we don't care about complexity
        foreach my $idx (grep { $_ % 2 == 0 } 0..$#extract_patterns) {
            # foreach extract pattern
            if ($post->{title} =~ /$extract_patterns[$idx]/i) {
                push @to_print, {
                    entry => $post,
                    type  => $extract_patterns[$idx+1]
                };
                next POST;
            }
        }
        foreach my $idx (grep { $_ % 2 == 0 } 0..$#extract_domains) {
            my $uri = URI->new($post->{url});
            my $host;
            next unless $uri->can('host');
            $host = $uri->host;
            if ($host =~ /$extract_domains[$idx]/i) {
                push @to_print, {
                    entry => $post,
                    type  => $extract_domains[$idx+1]
                };
                next POST;
            }
        }
    }

    print_entries(\@to_print);
}

#
# print_entries
#
# Given a arrayref of entries, prints one by one in our desired format.
#
sub print_entries {
    my $entries = shift;
    foreach (@$entries) {
print "$_->{entry}->{title} ($_->{type}, $_->{entry}->{user}, $_->{entry}->{id}, $_->{entry}->{url})\n";
    }
}

#
# extract_posts
#
# Subroutine takes HTML content of reddit's page and returns an array
# of hashes containing information about each post on the page.
#
sub extract_posts {
    my $content = shift or
        die "error: no content provided to extract_posts";

    my @posts;
    my $tree = HTML::TreeBuilder->new;
    $tree->parse($content);

    # if we look how the reddit is made in FireBug, we see that each link
    # is a row of a big HTML table.
    # each row has 'class' attribute named 'evenRow' or 'oddRow'
    #
    my %post_entry;
    my @trs = $tree->look_down("_tag" => "tr", "class" => qr{evenRow|oddRow});
    foreach my $tr (@trs) {
        my $link = $tr->look_down("_tag" => "a", "id" => qr{title\d+});
        unless (defined $link) {
            # if link is not defined, it means that we have the row containing user info
            # and id of reddit url for comments, and score
            my ($ulink, $clink) = $tr->look_down("_tag" => "a");
            next unless (defined $ulink and defined $clink);

            my $user = $ulink->as_text;
            $user =~ s/\s+$//g;
            $post_entry{user} = $user;

            my $chref = $clink->attr('href');
            next unless $chref;
            if ($chref =~ m{/info/([^/]+)/comments}) {
                $post_entry{id} = $1;
            }

            my $score_span = $tr->look_down("_tag" => "span", id => qr{score\d+});
            if ($score_span) {
                my $score_text = $score_span->as_text;
                if ($score_text =~ /(\d+) point/) {
                    $post_entry{score} = $1;
                }
            }

            unless (exists $post_entry{score}) {
                # could be that the entry was posted less than hour ago,
                # then it has no score visible
                $post_entry{score} = 0;
            }
  
            if ($post_entry{score} >= VOTE_THRESHOLD) {
                push @posts,  { %post_entry };
            }
            next;
        }

        # get the title, strip leading spaces
        my $title = decode_entities($link->as_text);
        $title =~ s/^\s+//g;

        my $url = $link->attr('href');

        $post_entry{title} = $title;
        $post_entry{url}   = $url;
    }

    $tree->delete;
    return @posts;    
}

#
# get_next_page_url
#
# Given HTML content of a reddit page, extracts url to the next page.
#
sub get_next_page_url {
    my $content = shift or
        die "error: no content provided to get_next_page";

    my $next_url;
    
    if ($content =~ m{<a.*?href="(/.*?)">next &raquo;</a>}) {
        $next_url = "http://reddit.com" . $1;
    }

    return $next_url;
}

