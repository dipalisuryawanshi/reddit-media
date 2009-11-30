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

use warnings;
use strict;

#
# This program was written as a part of "reddit media: intelligent fun online"
# website generator.
# This website can be viewed here: http://redditmedia.com 
#
# See http://www.catonmat.net/designing-reddit-media-website for more info.
#

use Template;               # for generating html pages from templates
use DBI;
use XML::RSS;
use POSIX;
use HTML::Entities;
use URI;
use URI::Escape;
use File::Basename;
use File::Find;
use File::Copy;
use File::Flock;
use List::Util 'max';
use open OUT => ':utf8';

use ThumbExtractor;
use ThumbMaker;
use ImageFinder;

# Print various debugging information to stderr
#
use constant DEBUG => 1;

# Path to lockfile to make sure 1 copy of this script is running at any time
#
use constant LOCK_FILE_PATH => '/mnt/evms/services/apache/wwwroot/redditmedia/locks/page_gen.lock';

# Number of items to display per page. note that the first page will always strech to 
# 2*ITEMS_PER_PAGE - 1 items (read about page generating algorithm in generate_pages subroutine).
#
use constant ITEMS_PER_PAGE  => 3;

# Number of items which appear in the feed
#
use constant ITEMS_PER_FEED => 15; 

# Path to webservers root directory which it will serve static pages from.
#
use constant WWW_PATH        => '/mnt/evms/services/apache/wwwroot/redditmedia/www'; 

# Path to html templates which will be used to make static pages.
#
use constant TEMPLATE_PATH   => '/mnt/evms/services/apache/wwwroot/redditmedia/templates';

# Temporary path for outputting compiled pages, after the pages have been generated
# they will be atomically renamed() to WWW_PATH.
#
use constant OUTPUT_TMP_PATH => '/mnt/evms/services/apache/wwwroot/redditmedia/tmp.www';

# Path to sqlite database which stores entries and some information about last script run.
#
use constant DATABASE_PATH   => '/mnt/evms/services/apache/wwwroot/redditmedia/db/media.db';

# Path to dir where the compiled (cached) entries will be stored.
#
use constant COMPILED_ENTRIES_PATH => '/mnt/evms/services/apache/wwwroot/redditmedia/compiled.entries';

# Path to already generated pages which once generated never change (except navigation).
# Read about algorithm in generate_pages subroutine's comments
#
use constant COMPILED_PAGES_PATH   => '/mnt/evms/services/apache/wwwroot/redditmedia/compiled.pages';

# Path to single entry link directory. That is where static pages of
# /link/<entry type>/<first char of entry title>/<entry title>.html are stored.
#
use constant LINK_DIR        => '/mnt/evms/services/apache/wwwroot/redditmedia/www/link'; # + /pictures or /videos

# To prevent filesystem bottlenecks, entry cache will be stored in a number of subdirs
# of COMPILED_ENTRIES_PATH. Based on entry ID, the compiled version will be stored in
# COMPILED_ENTRIES_PATH/(integer part of(id/ITEMS_PER_CACHE_DIR) * ITEMS_PER_CACHE_DIR).
# For example if ENTRIES_PER_DIR is 1000, then entry with id 25 will be stored
# in COMPILED_ENTRIES_PATH/0 dir, entry with id 1832 in COMPILED_ENTRIES_PATH/1000, etc.
#
# The same happens for cached image thumbnails in IMAGE_CACHE_PATH
#
use constant ITEMS_PER_CACHE_DIR => 1000;

# Most sites do not provide thumbnails, in this case we retrive the picture and
# cache it locally in IMAGE_CACHE_PATH
#
use constant IMAGE_CACHE_PATH => "/mnt/evms/services/apache/wwwroot/redditmedia/www/image.cache";

# The relative path to WWW when a cached icon is accessed from web server
#
use constant IMAGE_RELATIVE_WWW => "/image.cache";

# To generate thumbnails, ImageCacher.pm module needs netpbm executables.
# This constant defines path to them
#
use constant NETPBM_PATH => "/home/pkrumins/tmpinstall/netpbm-10.26.44/foobarbaz/bin";

lock_script();

my $regenerate = shift || 0;  # if regenerate is set, all the pages will be regenerated!
                              # useful if html templates have changed

clear_cache() if $regenerate;

my $dbh = DBI->connect("dbi:SQLite:" . DATABASE_PATH, '', '', { RaiseError => 1 });
die $DBI::errstr unless $dbh;

try_create_status_db();

my %new_entries = get_new_entries('main'); # get all new entries
exit 0 unless keys %new_entries;          # exit if no new entries

my $template = Template->new({
        INCLUDE_PATH => TEMPLATE_PATH,
        OUTPUT_PATH  => OUTPUT_TMP_PATH,
        ABSOLUTE     => 1
});

# Get top users and top hosts
my @top_users = get_top_users();
my @top_hosts = get_top_hosts();

#
# First let's generate cache of the entries, they will be put in COMPILED_ENTRIES_PATH directory
# and named $id-$type.html, where $id is the id of primary key of the entry in database and
# $type is type of link (picture, pictures, video, videos, etc.).
# They will still contain [% entry.pos %] template variable which should be replaced
# with the correct position in the page (1, 2, 3, ..., etc).
#
# Also after each cache entry has been generated, create the
# /<media type>/<first title alnum char>/title.html page to have something indexed in google
#
foreach my $entry_id (keys %new_entries) {
    generate_entry_cache($new_entries{$entry_id});    
    generate_link($new_entries{$entry_id});
}

generate_pages('main',     \%new_entries);
generate_pages('pictures', {get_new_entries('pictures')});
generate_pages('videos',   {get_new_entries('videos')});

update_rss_feed();

# Now, do the atomic rename() of index pages
#
my @new_indexes = glob(OUTPUT_TMP_PATH . "/*.html");
rename $_ => WWW_PATH . '/' . basename($_) foreach @new_indexes;

update_status_db();

#
# lock_script
#
# Exclusively locks a file, so we had always 1 copy of script running at any
# given moment
#
sub lock_script {
    my $ret = lock(LOCK_FILE_PATH, undef, 'nonblocking');
    unless ($ret) {
        print "Script already running. Quitting.\n";
        exit 1;
    }
}

#
# clear_cache
#
# Function deletes all *.html files in OUTPUT_TMP_PATH and
# COMPILED_{ENTRIES,PAGES}_PATH directories
#
sub clear_cache {
    unlink glob(OUTPUT_TMP_PATH       . "/*.html");
    unlink glob(COMPILED_PAGES_PATH   . "/*.html");

    my @entry_sub_dirs = grep -d, glob(COMPILED_ENTRIES_PATH . "/*");
    foreach (@entry_sub_dirs) {
        unlink glob($_ . "/*.html");
    }

}

#
# update_rss_feed
#
# Function takes last ITEMS_PER_FEED entries from the database and
# generates the RSS feed for the media
#
# TODO: separate this out into a template
#
sub update_rss_feed {
    my $rss = XML::RSS->new(version => '2.0');
    $rss->channel(
        title           =>  "reddit media: intelligent fun online",
        link            =>  "http://redditmedia.com",
        description     =>  "intelligent media from reddit.com",
        language        =>  "en",
        copyright       =>  "redditmedia.com (c) Peteris Krumins, the content (c) reddit.com",
        webMaster       =>  'peter@catonmat.net',
        managingEditor  =>  'peter@catonmat.net',
        pubDate         =>  "2007-08-20 20:00",
        lastBuildDate   =>  strftime("%Y-%m-%d %H:%M:%S", localtime),
        generator       =>  "redditmedia.com static page generator"
    );

    $rss->image(
        title           =>  "reddit media: intelligent fun online",
        url             =>  "http://redditmedia.com/logo.gif",
        link            =>  "http://redditmedia.com",
        width           =>  120,
        height          =>  40,
        description     =>  "reddit alien, meow"
    );

    my $last_entries_query = "SELECT * FROM reddit ORDER BY id DESC LIMIT " . ITEMS_PER_FEED;
    my $last_entries = $dbh->selectall_hashref($last_entries_query, ['id']);

    foreach my $id (sort { $b <=> $a } keys %$last_entries) {
        $rss->add_item(
            title       =>  $last_entries->{$id}->{title},
            permaLink   =>  $last_entries->{$id}->{url},
            comments    =>  "http://reddit.com/info/$last_entries->{$id}->{reddit_id}/comments",
            pubDate     =>  $last_entries->{$id}->{date_added},
            category    =>  $last_entries->{$id}->{type},
            dc => {
              creator   => "reddit.com"
            }
        );
    }

    $rss->save(WWW_PATH . "/feed.html");
}

#
# try_create_status_db 
#
# Creates a status db if does not exist
#
sub try_create_status_db {
    my $table_exists = 0;
    my $tables_q = "SELECT name FROM sqlite_master WHERE type='table' AND name='reddit_status'";
    my $res = $dbh->selectall_arrayref($tables_q);

    if (defined $res and @$res) {
        $table_exists = 1;
    }

    unless ($table_exists) {
        my $create_db =<<EOL;
CREATE TABLE reddit_status (
    last_id  INTEGER NOT NULL,
    last_run DATE    NOT NULL
)
EOL
        $dbh->do($create_db);
    }
}

#
# update_status_db
#
# Updates status information abour last run and last generated id.
#
sub update_status_db {
    my $has_records = "SELECT * FROM reddit_status";
    my $records = $dbh->selectall_arrayref($has_records);

    my $last_run = strftime("%Y-%m-%d %H:%M:%S", localtime);
    my $max_id = max keys %new_entries;
    if (defined $records and @$records) {
        # Update the status table
        #
        $dbh->do("UPDATE reddit_status SET last_id  = '$max_id'");
        $dbh->do("UPDATE reddit_status SET last_run = '$last_run'");
    }
    else {
        # Insert new status
        #
        $dbh->do("INSERT INTO reddit_status (last_id, last_run) VALUES ('$max_id', '$last_run')");
    }
}

#
# generate_pages
#
# Given a hashref of new entries and the page type, the function generates
# pages of given type and outputs them to OUTPUT_TMP_PATH directory.
#
# Function uses the generated cache entries.
#
sub generate_pages {
    my ($page_type, $new_entries) = @_;

    my @compiled_entries = get_compiled_entries($page_type);
    my @index_pages      = get_index_pages($page_type);

    #
    # I want to regenerate pages as little as possible, to keep things running quick.
    # Here is the algorithm which splits the entries to pages and makes them never change.
    # Only the first page changes at any time.
    #
    # Let T be total number of entries, IPP be items per page to display.
    # The first page will have maximum 2 * IPP - 1 entries. Given T entries, it is first filled
    # with IPP entries and then with T%IPP. IPP is now a divisor of the remaining
    # number of entries T - (IPP + T%IPP).
    #
    # Now we just have to update the main page and offset other pages
    # 

    my ($total_entries, $total_pages) = (scalar @compiled_entries, scalar @index_pages);
    my $extra_entries = $total_entries % ITEMS_PER_PAGE; # number of extra entries on first page
    my $first_page_entries = ITEMS_PER_PAGE + $extra_entries;

    if ($first_page_entries > $total_entries) {
        $first_page_entries = $total_entries;
    }

    # Generate first page (index.html or index-pictures.html, etc).
    my @gen_entries;
    for my $entry_idx (0 .. $first_page_entries - 1) {
        push @gen_entries, {
            file => $compiled_entries[$entry_idx],
            pos  => $total_entries - $entry_idx
        }
    }
    generate_page($page_type, 1, $total_entries, \@gen_entries);

    if ($total_pages <= 1 || $regenerate) {
        # no existing index pages for this page_type
        # generate all pages!
        my $current_page = 2;
        my $current_item = 1;
        @gen_entries = ();
        for my $entry_idx ($first_page_entries .. $#compiled_entries) {
            push @gen_entries, {
                file => $compiled_entries[$entry_idx],
                pos  => $total_entries - $entry_idx
            };

            if ($current_item % ITEMS_PER_PAGE == 0) { 
                generate_page($page_type, $current_page, $total_entries, \@gen_entries);
                @gen_entries = (); 
                $current_page++;
            }
            $current_item++;
        }
    }
    else { 
        # Generate only the new pages.
        # We determine how many new pages will be created and just rename the existing ones
        # by that number. This way we avoid regenerating the existing pages.
        #
        my $pages_required = ($total_entries - $first_page_entries)/ITEMS_PER_PAGE; # pages required to fit the left entries
        my $page_offset = ($pages_required + 1) - $total_pages; # +1 because of the first page (plain index.html)

        if ($page_offset) {
            my $total_new_entries = keys %$new_entries;
            my $entry_offset = ITEMS_PER_PAGE + $extra_entries;

#            print "tot ent:     $total_entries\n";
#            print "1st p ent:   $first_page_entries\n";
#            print "total pages: $total_pages\n";
#            print "pages req:   $pages_required\n";
#            print "page offset: $page_offset\n";
#            print "tot new en:  $total_new_entries\n",
#            print "ent offset:  $entry_offset\n";

            # copy the other pages to new page numbers (moved later back to WWW_PATH)
            #
            for my $page_number (2 .. $total_pages) {
                my $new_page_number = $page_number + $page_offset;
                my $src = COMPILED_PAGES_PATH  . '/' . get_page_name($page_type, $page_number);
                my $dst = get_page_name($page_type, $new_page_number);
                my $data = {
                    navigation => build_navigation($total_entries, $page_type, $new_page_number),
                    topusers   => \@top_users,
                    tophosts   => \@top_hosts
                };
                $template->process($src, $data, $dst, binmode => ':utf8');
            }

            # since generate_page will be creating new index pages and their compiled versions
            # we need to change their indexes
#            for my $page_number (reverse 2 .. $total_pages) {
#                my $src = COMPILED_PAGES_PATH . '/' . get_page_name($page_type, $page_number);
#                my $dst = COMPILED_PAGES_PATH . '/' . get_page_name($page_type, $page_number + $page_offset);
#                rename $src => $dst;
#            }

            my $current_page = 2;
            my $current_item = 1;
            @gen_entries = ();
            for my $entry_idx ($entry_offset .. $entry_offset + $pages_required * ITEMS_PER_PAGE - 1) {
                push @gen_entries, {
                    file => $compiled_entries[$entry_idx],
                    pos  => $total_entries - $entry_idx
                };

                if ($current_item % ITEMS_PER_PAGE == 0) {
                    generate_page($page_type, $current_page, $total_entries, \@gen_entries);
                    @gen_entries = (); 
                    $current_page++;
                }
                $current_item++;
            }
        }
    }
}

#
# generate_page
#
# Given a page type, page number and entries, the function generates a static
# HTML page and puts it in OUTPUT_TMP_PATH directory
#
sub generate_page {
    my ($page_type, $page_number, $total_entries, $entries) = @_;

    my $outpage = get_page_name($page_type, $page_number);
    my $data = {
        last_update  => strftime("%Y-%m-%d %H:%M:%S", localtime),
        navigation   => build_navigation($total_entries, $page_type, $page_number),
        entries      => $entries,
        page_type    => $page_type,
        topusers     => \@top_users,
        tophosts     => \@top_hosts,
    };
    $template->process('index.html', $data, $outpage, binmode => ':utf8');

    # create a compiled version which will be used when moving pages
    $data->{navigation}   = '[% navigation %]';
    $data->{topusers_tpl} = 1;   # include top user template
    $data->{tophosts_tpl} = 1;   # include top host template
    my $output;
    $template->process('index.html', $data, \$output);

    my $file_path = COMPILED_PAGES_PATH . "/$outpage";
    open my $out, '>', $file_path or die "Error: could not open '$file_path': $!";
    print $out $output;
    close $out;
}

#
# get_page_name
#
# Given page type and page number, generates an index page filename
#
sub get_page_name {
    my ($page_type, $page_number) = @_;

    my $outpage;
    if ($page_type eq 'main') {
        $outpage = $page_number == 1 ? "index.html" : "index-$page_number.html";
    }
    else {
        $outpage = $page_number == 1 ? "index-$page_type.html" : "index-$page_type-$page_number.html";
    }
    return $outpage;
}

#
# build_navigation
#
# given total number of entries, function builds navigation html code 
# for a given type of page (main, pictures or videos)
#
sub build_navigation {
    my ($total_entries, $type, $current) = @_;
    $current ||= -1;
    my $pages = int $total_entries / ITEMS_PER_PAGE;

    my @navarr;
    for my $page (1 .. $pages) {
        # build page names
        #
        my $page_name; 
        if ($type eq "main") {
            $page_name = "index";
        }
        else {
            $page_name = "index-$type";
        }
        
        unless ($page == 1) {
            $page_name .= "-$page";
        }
        $page_name .= ".html";
        
        my $nav = {
            href    => $page_name,
            page    => $page,
            current => $current
        };
        push @navarr, $nav;
    }

    my $output = '';
    $template->process('navigation.html', { navs => \@navarr }, \$output);

    return $output;
}

#
# generate_link
#
# Given a reddit entry, function generates /link/<first title letter>/entry-title.html page
#
sub generate_link {
    my $entry = shift;

    my $entry_data = {
        icon           => get_icon($entry),
        title          => encode_entities($entry->{title}),
        title_uri_esc  => uri_escape($entry->{title}),
        sane_title     => sanitize_title($entry->{title}),
        host           => get_host($entry->{url}),
        link_dir       => get_link_dir($entry->{type}),
        user           => encode_entities($entry->{user}),
        url            => $entry->{url},
        url_uri_esc    => uri_escape($entry->{url}),
        date_added     => $entry->{date_added},
        reddit_id      => $entry->{reddit_id}
    };

    my %link_data = (
        last_update  => strftime("%Y-%m-%d %H:%M:%S", localtime),
        title        => encode_entities($entry->{title}),
        topusers     => \@top_users,
        tophosts     => \@top_hosts
    );

    my $output;
    $template->process('link.html', { entry => $entry_data, %link_data }, \$output);

    # build path to link file
    my $link_path = LINK_DIR;
    $link_path .= "/pictures" if $entry->{type} =~ /picture/;
    $link_path .= "/videos"   if $entry->{type} =~ /video/;

    unless (-d $link_path) {
        mkdir $link_path or die "Error: could not create '$link_path': $!";
    }

    $link_path .= '/' . substr($entry_data->{sane_title}, 0, 1);
    unless (-d $link_path) {
        mkdir $link_path or die "Error: could not create '$link_path': $!";
    }

    $link_path .= "/$entry_data->{sane_title}.html";

    open my $out, '>', $link_path or die "Error: could not open '$link_path': $!";
    print $out $output;
    close $out;
}

#
# generate_entry_cache
#
# The function takes a reddit article entry and generates an entry cache file.
#
sub generate_entry_cache {
    my $entry = shift;

    return if !$regenerate and -e COMPILED_ENTRIES_PATH . "/$entry->{id}-$entry->{type}.html";

    my $entry_data = {
        icon           => get_icon($entry),
        title          => encode_entities($entry->{title}),
        title_uri_esc  => uri_escape($entry->{title}),
        sane_title     => sanitize_title($entry->{title}),
        host           => get_host($entry->{url}),
        link_dir       => get_link_dir($entry->{type}),
        user           => encode_entities($entry->{user}),
        url            => $entry->{url},
        url_uri_esc    => uri_escape($entry->{url}),
        date_added     => $entry->{date_added},
        reddit_id      => $entry->{reddit_id}
    };
    $entry_data->{title_first_char} = substr($entry_data->{sane_title}, 0, 1);

    my $output = '';
    $template->process('index_entry.html', { entry => $entry_data } , \$output);

    my $entry_dir = COMPILED_ENTRIES_PATH . '/' . get_cache_subdir($entry->{id});
    unless (-d $entry_dir) {
        mkdir $entry_dir or die "Error: could not create '$entry_dir': $!";
    }

    my $file_path = "$entry_dir/$entry->{id}-$entry->{type}.html";
    open my $out, '>', $file_path or die "Error: could not open '$file_path': $!";
    print $out $output;
    close $out;
}

#
# get_cache_subdir
#
# Calculates cache subdir, see comments of ITEMS_PER_CACHE_DIR constant
#
sub get_cache_subdir {
    my $id = shift;
    return (int $id / ITEMS_PER_CACHE_DIR) * ITEMS_PER_CACHE_DIR;
}

#
# get_compiled_entries
#
# Given page_type, the function returns a list of compiled (cached) entries for a given type
#
sub get_compiled_entries {
    my $page_type = shift;

    my $entry_search_glob;
    if ($page_type eq 'main') {
        $entry_search_glob = "/*.html";
    }
    elsif ($page_type eq "pictures") {
        $entry_search_glob = "/*{picture,pictures}.html";
    }
    elsif ($page_type eq "videos") {
        $entry_search_glob = "/*{video,videos}.html";
    }

    my @entries;
    my @entry_sub_dirs = grep -d, glob(COMPILED_ENTRIES_PATH . "/*");
    foreach (@entry_sub_dirs) {
        my @subentries = glob($_ . $entry_search_glob);
        push @entries, @subentries;
    }

    # sort compiled entries by id and then reverse the list so the list began with newest entries
    my @compiled_entries = reverse sort {;
        no warnings 'numeric';
        int basename($a) <=> int basename($b)
    } @entries;

    return @compiled_entries;
}

#
# get_index_pages
#
# Given page_type, the function returns a list of existing index*.html pages
#
sub get_index_pages {
    my $page_type = shift;

    my @index_pages;
    if ($page_type eq 'main') {
        # can't use a glob on main page because an 'index*.html' glob
        # would match picture and video index pages as well
        find(sub {
                push @index_pages, $File::Find::name if $_ =~ /index(-\d+)?\.html$/
            }, WWW_PATH
        );
    }
    else {
        my $page_search_glob = "/index-$page_type*.html";
        @index_pages = glob(WWW_PATH . $page_search_glob);
    }

    my @sorted_index_pages = sort {
        my $rx = qr/(\d+)\.html$/;
        my ($an) = $a =~ /$rx/;
        my ($bn) = $b =~ /$rx/;
        return 1 unless defined $bn and defined $an;  # take care of default pages like 'index.html'
        $an <=> $bn;
    } @index_pages;

    return @sorted_index_pages;
}

#
# get_link_dir
#
# Given entry's type, returns link directory.
#
sub get_link_dir {
    my $type = shift;

    return "videos"   if ($type =~ /video/);
    return "pictures" if ($type =~ /picture/);
    die "unknown entry type: $type";
}

#
# get_icon
#
# Given an entry, the function gets a thumbnail (icon) for the entry.
# For example, for youtube videos it gets thumbnail from youtube's servers.
# Or, for some blogspot page it tries to find the first image in the content,
# download it, make a thumbnail and cache it locally.
#
sub get_icon {
    my $entry = shift;

    my $sane_title = sanitize_title($entry->{title});
    my $cached_icon_path =  IMAGE_CACHE_PATH   . '/' . get_cache_subdir($entry->{id});
    unless (-d $cached_icon_path) {
        mkdir $cached_icon_path;
    }
    $cached_icon_path .= "/$entry->{id}-$sane_title.jpg";

    my $rel_www_icon_path = IMAGE_RELATIVE_WWW . '/' . get_cache_subdir($entry->{id});
    unless (-d $rel_www_icon_path) {
        mkdir $rel_www_icon_path;
    }
    $rel_www_icon_path .= "/$entry->{id}-$sane_title.jpg";

    return $rel_www_icon_path if -e $cached_icon_path; # return cached icon

    my $thex = ThumbExtractor->new;
    my $thumb = $thex->get_thumbnail($entry->{url});

    unless (defined $thumb) { # no thumb was found
        if ($entry->{type} =~ /video/) {
            # each video site requires a custom written handler for extracting thumbnails
            # if there was none, display default icon
            print STDERR "Couldn't extract thumbnail for video site at '$entry->{url}'\n" if DEBUG;
            return get_default_icon($entry->{type});
        }

        # let's find the best image on the page
        my $image_finder = ImageFinder->new(netpbm => NETPBM_PATH);
        my $best_img = $image_finder->find_best_image($entry->{url});

        unless ($best_img) { # no best image, hmm.
            print STDERR "No best image was found at '$entry->{url}'\n" if DEBUG;
            return get_default_icon($entry->{type});
        }

        # create a thumbnail for this image
        my $thumb_maker = ThumbMaker->new(netpbm  => NETPBM_PATH);
        my $success = $thumb_maker->create_thumbnail($best_img, $cached_icon_path,
            { width => 77, height => 77, border => 1, border_color => '#C7DEF7' });

        unlink $best_img;
        unless ($success) {
            print STDERR $thumb_maker->get_error, "\n" if DEBUG;
            return get_default_icon($entry->{type});
        }

        return $rel_www_icon_path;
    }

    if ($thumb->is_thumb) { # a real thumbnail
        return $thumb->url;
    }
    else { # just an image
        my $thumb_maker = ThumbMaker->new(netpbm  => NETPBM_PATH);
        my $success = $thumb_maker->create_thumbnail($thumb->url, $cached_icon_path,
            { width => 77, height => 77, border => 1, border_color => '#C7DEF7' });

        unless ($success) {
            print STDERR $thumb_maker->get_error, "\n" if DEBUG;
            return get_default_icon($entry->{type});
        }
    }
    return $rel_www_icon_path;
}

#
# get_default_icon
#
sub get_default_icon {
    my $type = shift;

    return "/icons/$type-big.gif";
}

#
# sanitize_title
#
# given a title of a reddit story, the function sanitizes the title:
# removes [ ]'s, ( )'s, etc. and then replaces all non alphanumeric chars with '-'
#
sub sanitize_title {
    my $title = lc shift;

    $title =~ s{\[|\]|\(|\)|'}{}g;
    $title =~ s/[^[:alnum:]]/-/g;
    
    # get rid of multiple -'s
    $title =~ s/-{2,}/-/g;

    # get rid of leading and trailing -'s
    $title =~ s/^-+|-+$//g;

    if (length $title > 100) {
        $title = substr($title, 0, 100);
        $title =~ s/-*$//g; # there might now be one - at the end again
        $title =~ s/-[[:alnum:]]*$//g;
    }

    return $title;
}

#
# get_host
#
# given a URL, the function returns host portion of it
#
sub get_host {
    my $url = shift;

    my $uri = URI->new($url);
    if ($uri->can('host')) {
        return $uri->host;
    }
    return "unknown";
}

#
# get_top_users
#
# Subroutine returns an array of hashrefs of top 10 users
# Each hash hash two keys 'user' and 'posts'
#
sub get_top_users {
    my $top_users_query =<<EOL;
SELECT user, count(user) as posts
 FROM reddit
GROUP BY user
 ORDER BY posts
DESC
 LIMIT 10
EOL
    my $top_users = $dbh->selectall_arrayref($top_users_query);
    my @ret;
    foreach (@$top_users) {
        push @ret, {
            user        => $_->[0],
            total_posts => $_->[1]
        }
    }
    return @ret;
}

#
# get_top_hosts
#
# Subroutine returns an array of hashrefs of top 10 domains
# Each hash hash two keys 'host' and 'posts'
#
sub get_top_hosts {
    my $urls_query = "SELECT url FROM reddit";
    my $urls = $dbh->selectall_arrayref($urls_query);

    my %hosts;
    foreach (@$urls) {
        my $uri = URI->new($_->[0]);
        if ($uri->can('host')) {
            my $host = $uri->host;
            $host =~ s/^www\.//;
            $host =~ s/.*?(\w+\.\w+)$/$1/;
            $hosts{$host}++;
        }
    }

    my @ret;
    my @sorted_keys = sort { $hosts{$b} <=> $hosts{$a} } keys %hosts;
    foreach (@sorted_keys[0..(@sorted_keys < 10 ? $#sorted_keys : 9)]) {
        push @ret, {
            host        => $_,
            total_posts => $hosts{$_}
        }
    }

    return @ret;
}

#
# get_new_entries
#
# Given the page type, function returns a hash of new entries, where hash key is
# the id of entry
#
sub get_new_entries {
    my $page_type = shift;

    my $entry_query;
    my $had_where = 0;
    my %run_status = get_run_status();
    if (exists $run_status{last_id} && !$regenerate) {
        $entry_query = "SELECT * FROM reddit WHERE id > $run_status{last_id}";
        $had_where = 1;
    }
    else {
        $entry_query = "SELECT * FROM reddit"
    }
    
    if ($page_type eq "pictures") {
        if ($had_where) {
            $entry_query .= " and";
        }
        else {
            $entry_query .= " WHERE";
        }
        $entry_query .= " type = 'picture' or type = 'pictures'";
    }
    elsif ($page_type eq "videos") {
        if ($had_where) {
            $entry_query .= " and";
        }
        else {
            $entry_query .= " WHERE";
        }
        $entry_query .= " type = 'video' or type = 'videos'";
    }

    my $entries = $dbh->selectall_hashref($entry_query, [ 'id' ]);

    return %{$entries || {}};
}

#
# get_run_status
#
# Queries the reddit_status table and returns a hash of status values
#
sub get_run_status {
    my $run_status = $dbh->selectrow_hashref("SELECT * FROM reddit_status");

    return %{$run_status || {last_id => 0}};
}

