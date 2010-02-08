#!/usr/bin/env ruby

# fugatrace  --  an execution tracer based on GDB
# Copyright (C) 2010  Shinichiro Hamaji <shinichiro.hamaji _at_ gmail.com>
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

GIT_ID = "$Id$"
GIT_HASH = GIT_ID[/ ([0-9a-f]+) /, 1]

require 'cgi'
require 'expect'
require 'optparse'

def usage(opt)
  puts "Usage: #$0 <args>..."
  puts opt.to_a[1..-1]
  exit 1
end

def escape_argv(argv)
  argv.map{|arg|
    arg =~ /^-/ ? arg : "'#{arg.gsub(/'/,'\&\&')}'"
  } * ' '
end

def parse_comma_separated_gdb_commands(specifier)
  cur_cmd = ''
  cmds = [cur_cmd]
  num_open_paren = 0
  was_backslash = false

  specifier.each_char do |c|
    if was_backslash
      cur_cmd << c
      was_backslash = false
    elsif c == '\\'
      was_backslash = true
    elsif c == '('
      cur_cmd << c
      num_open_paren += 1
    elsif c == ')'
      cur_cmd << c
      num_open_paren -= 1
      if num_open_paren < 0
        raise "Unmatched parentheses"
      end
    elsif c == ',' && num_open_paren == 0
      cur_cmd = ''
      cmds << cur_cmd
    else
      cur_cmd << c
    end
  end
  cmds
end

def check_parse_comma_separated_gdb_commands
  num_fails = 0
  assert_equal = proc{|expected, actual|
    if expected != actual
      STDERR.puts "expected %p, but comes %p" % [expected, actual]
      num_fails += 1
    end
  }

  assert_equal[['p foo; p *bar@baz.c:22'],
               parse_comma_separated_gdb_commands('p foo; p *bar@baz.c:22')]
  assert_equal[['foo', 'p f(1,2)@baz.c:22'],
               parse_comma_separated_gdb_commands('foo,p f(1,2)@baz.c:22')]
  assert_equal[['foo', 'comma,.c:22'],
               parse_comma_separated_gdb_commands('foo,comma\\,.c:22')]
  assert_equal[['foo', 'comma\\', '.c:22'],
               parse_comma_separated_gdb_commands('foo,comma\\\\,.c:22')]

  raise if num_fails > 0
end
check_parse_comma_separated_gdb_commands

class GDB
  def initialize(argv, logfile)
    @cmd, *argv = *argv
    @argv = escape_argv(argv)
    if logfile
      @log = File.open(logfile, 'w')
    end
    @gdb = IO.popen("gdb #{@cmd} 2>&1", "r+")
  end

  def quit
    @log.close if @log
    @gdb.close
  end

  def expect(pat)
    r = @gdb.expect(pat, 10000)
    if !r
      while c = @gdb.getc
        STDOUT.putc c
        STDOUT.flush
      end
    end
    if @log
      @log << r[0]
    end
    r
  end

  def expect_prompt
    r = self.expect('(gdb) ')
    r[0].sub!('(gdb) ', '')
    r
  end

  def command(cmd)
    puts(cmd)
    lines = *expect_prompt
  end

  def puts(cmd)
    if @log
      @log.puts(cmd)
      @log.flush
    end
    @gdb.puts(cmd)
  end

  def start
    puts("start #{@argv}")
  end

  def cmdline
    "#{@cmd} #{@argv}"
  end
end

OPENED_NODE = '-'
CLOSED_NODE = '+'

exit_message = %Q(<p style="color:red">fugatrace BUG: no exit messages)
func_regexp = ''
exclude_func_regexp = nil
output_html = 'trace.html'
logfile = nil
simple = false
# TODO: implement abbreviation?
abbreviate_same_children = 3
original_args = escape_argv(ARGV)
breakpoint_specifiers = ''

# TODO: re-organize command line options. Maybe -r -R -f -F -g .
# TODO: file name suppression

OptionParser.new do |opt|
  opt.on('-h', '--help') { usage(opt) }
  opt.on('-r', '--regexp FUNC-REGEXP') {|v| func_regexp = v }
  opt.on('-R', '--exclude-regexp FUNC-REGEXP') {|v| exclude_func_regexp = v }
  opt.on('-o', '--output FILENAME') {|v| output_html = v }
  opt.on('-l', '--logfile [FILENAME]') {|v| logfile = v || 'trace_log.txt' }
  opt.on('-s', '--simple') { simple = true }
  opt.on('-a', '--abbreviate NUM', Integer) {|v| abbreviate_same_children = v }
  opt.on('-b', '--breakpoints [BREAKS]',
         "comma separated list of [GDB-COMMAND@]GDB-BREAK (e.g., 'p var@test.c:3')") {|v|
    breakpoint_specifiers = v
  }

  opt.parse!(ARGV)

  unless ARGV[0]
    usage(opt)
  end
end

gdb = GDB.new(ARGV, logfile)
gdb.expect_prompt

gdb.command("set pagination 0")

gdb.start
gdb.expect_prompt

stopped = []
stop_positions = []
stop_functions = []

breakpoints = {}
parse_comma_separated_gdb_commands(breakpoint_specifiers).each do |breakpoint_specifier|
  a = breakpoint_specifier.split('@')
  gdb_cmds = []
  if a.size == 2
    gdb_cmds = a[0].split(';')
    break_pos = a[1]
  elsif a.size == 1
    break_pos = a[0]
  else
    raise "Illformed breakpoint specifier: #{breakpoint_specifier}"
  end

  puts "Setting breakpoint #{break_pos}..."
  lines = gdb.command("break #{break_pos}")
  lines.scan(/^Breakpoint (\d+) at (.*)\./) do
    breakpoint_id = $1.to_i
    breakpoints[breakpoint_id] = gdb_cmds
    stopped[breakpoint_id] = []
    stop_positions[breakpoint_id] = $2
  end
end

puts "Setting breakpoints for symbols... (this may take long time without -r option)"
# TODO: We may want to use info functions instead of rbreak.
lines = gdb.command("rbreak #{func_regexp}")
if exclude_func_regexp
  exclude_func_regexp = /\b#{exclude_func_regexp}\(/
end
breakpoint_id = nil
lines.each do |line|
  if /^Breakpoint (\d+) at (.*)\./ =~ line
    breakpoint_id = $1.to_i
    stop_positions[breakpoint_id] = $2
  else
    if !breakpoint_id
      STDERR.puts lines
      raise
    end
    if exclude_func_regexp && exclude_func_regexp =~ line
      gdb.command("disable #{breakpoint_id}")
    else
      stopped[breakpoint_id] = []
    end
    breakpoint_id = nil
  end
end

puts "Start the program."
gdb.puts("cont")

li_num = 0
current_node = nil

class CallTree
  attr_accessor :parent, :ret
  attr_reader :bt

  def initialize(call, li_num, bt, cmds)
    @call = call
    @li_num = li_num
    @bt = bt
    @children = []
    @parent = nil
    @cmds = cmds
  end

  def add_child(child)
    @children << child
    child.parent = self
  end

  def emit(html)
    children_toggler, style =
      if leaf?
        ['', '']
      else
        [%Q(<a class="open" onclick="u(#{@li_num},this)">#{OPENED_NODE}</a>), ' class="toggle"']
      end
    ret = if @ret == :dup
            style = ' style="list-style-type:circle"'
            ''
          else
            " => #{@ret}"
          end
    html.puts %Q(<li#{style} id="l#{@li_num}">#{children_toggler}<span onclick="d('d#{@li_num}')">#{CGI.escapeHTML(@call)}#{ret}</span>)

    html.puts %Q(<div id="d#{@li_num}"><pre>#{CGI.escapeHTML(@bt*"\n")}</pre>)
    @cmds.each do |gdb_cmd, result|
      html.puts %Q(#{gdb_cmd}<pre>#{CGI.escapeHTML(result)}</pre>)
    end
    html.puts "</div>"

    if !leaf?
      html.puts %Q(<ul id="u#{@li_num}">)

      @children.each do |child|
        child.emit(html)
      end

      html.puts "</ul>"
    end
  end

  def root
    n = self
    while n.parent
      n = n.parent
    end
    n
  end

  def leaf?
    @children.empty?
  end

end

html = File.open(output_html, 'w')
begin
  html.puts(%Q(<!DOCTYPE HTML>
<html>
<head>
 <title>Trace of #{gdb.cmdline}</title>
 <script>
   function d(id) {
     var e = document.getElementById(id);
     if (e.style.display == 'block')
       e.style.display = 'none';
     else
       e.style.display = 'block';
     return e;
   }

   function u(id, self) {
     var e = document.getElementById('u' + id);
     if (e.style.display == 'none') {
       e.style.display = 'block';
       self.innerHTML = '#{OPENED_NODE}';
       self.className = 'open';
     } else {
       e.style.display = 'none';
       self.innerHTML = '#{CLOSED_NODE}';
       self.className = 'close';
     }
     event.stopPropagation();
   }

   // TODO: need to be disabled for Firefox.
   function doCopy(str) {
     var orig_scroll_left = document.body.scrollLeft;
     var orig_scroll_top = document.body.scrollTop;
     var t = document.createElement('textarea');
     document.body.appendChild(t);
     t.focus();
     document.execCommand('InsertText', false, str);
     t.select();
     document.execCommand('Copy');
     document.body.removeChild(t);
     window.scrollTo(orig_scroll_left, orig_scroll_top);
   }

   function copy(id) {
     var e = document.getElementById('copyable' + id);
     doCopy(e.innerHTML);
     return false;
   }
 </script>
 <style>
   body {
     font-family: sans-serif;
   }

   pre {
     color: #222;
     background-color:#f2f2f2;
   }

   li > div {
     display: none;
     /* font-size: small; */
     /* padding-left: 3em; */
   }

   li {
     list-style-type: square;
   }

   .toggle {
     list-style-type: none;
     position: relative;
     margin-top: 0.2em;
     margin-bottom: 0.2em;
   }

   li > a {
     position: absolute;
     top: auto;
     left: -2em;
     border: solid 1px;
     text-align: center;
     font-size: 0.7em;
     text-decoration: none;
     width: 1.3em;
     height: 1.3em;
   }

   li > a.close {
     color: #fff;
     background-color: #888;
     border-color: #333;
   }
   li > a:hover.close {
     color: #fff;
     background-color: #bbb;
     cursor: pointer;
     border-color: #aaa;
   }

   li > a.open {
     color: #888;
     background-color: #eee;
     border-color: #aaa;
   }
   li > a:hover.open {
     color: #eee;
     background-color: #888;
     cursor: pointer;
     border-color: #888;
   }
 </style>
</head>

<body>
))

  html.puts "<h1>The Information of This Trace</h1>"
  html.puts "<dl>"
  [['program', gdb.cmdline],
   ['command line options', original_args]].each_with_index do |a, i|
    dt, dd = *a
    html.puts %Q(<dt>#{dt} (<a href="javascript:copy(#{i})">copy</a>)</dt><dd><pre id="copyable#{i}">#{CGI.escapeHTML(dd)}</pre></dd>)
  end
  if logfile
    html.puts %Q(<dt>trace log</dt><dd><a href="#{logfile}">#{CGI.escapeHTML(logfile)}</a></pre></dd>)
  end
  html.puts "<dt>created time</dt><dd>#{Time.now}</dd>"
  html.puts '<dt>generated by</dt><dd><a href="http://github.com/shinh/fugatrace">fugatrace</a> %s</dd>' % GIT_HASH
  html.puts "</dl>"

  html.puts "<h1>The Trace</h1><ul>"

  while true
    lines = *gdb.expect_prompt

    if (/(Program exited (with code \d+|normally\.))\n/ =~ lines ||
        /(Program (received|terminated with) signal \w+, .*\.)\n/ =~ lines)
      puts $1
      exit_message = $1
      gdb.puts('quit')
      break
    end

    if simple
      if /Breakpoint (\d+), ((\w+) \(.* at .*:\d+)\n/ =~ lines
        puts $2
        html.puts "<li>#$2"
        gdb.puts('cont')
      else
        raise
      end
    else
      if /Breakpoint (\d+), ((\w+) \(.* at .*:\d+)\n/ =~ lines
        breakpoint_id = $1.to_i
        call = $2
        stop_functions[$1.to_i] = $3

        bt = gdb.command('bt').split("\n")

        #gdb.puts('info args')
        #args = *gdb.expect_prompt

        is_deeper = !current_node || current_node.bt.size < bt.size
        is_explicit_break = breakpoints.has_key?(breakpoint_id)

        if is_deeper || is_explicit_break
          puts call

          stopped[breakpoint_id] << li_num

          cmds = []
          if is_explicit_break
            gdb_cmds = ['info local'] + breakpoints[breakpoint_id]
            gdb_cmds.each do |gdb_cmd|
              lines = gdb.command(gdb_cmd)

              cmds << [gdb_cmd, lines]
            end
          end

          node = CallTree.new(call, li_num, bt, cmds)
          if current_node
            current_node.add_child(node)
          end

          if is_deeper
            current_node = node
          else
            node.ret = :dup
          end

          li_num += 1
        else
          # This is the workaround of a gdb's issue.
          # For program like f(){while(x)g();}, the following
          # situation may happen:
          #   1. f()'s breakpoint => finish
          #   2. g()'s breakpoint => finish
          #   3. g() finished, now we are in f() => finish
          #   4. f()'s breakpoint!
          # Without the check of backtrace size here, we'll interpret
          # 4 as f()'s recursive function call.
          raise if current_node.bt.size > bt.size
        end
        gdb.puts('finish')
      elsif /Value returned is \$\d+ = (.*)/ =~ lines || /Run till exit from/ =~ lines
        current_node.ret = $1 ? $1 : 'void'

        if current_node.parent
          prev_bt = current_node.bt
          current_node = current_node.parent

          next_frame_number = prev_bt.size - current_node.bt.size - 1

          if next_frame_number == -1
            STDERR.puts "invalid next frame"
            STDERR.puts "prev_bt:"
            STDERR.puts prev_bt
            STDERR.puts "current_node.bt:"
            STDERR.puts current_node.bt
            raise
          end

          if next_frame_number > 0
            gdb.command("f #{next_frame_number}")
          end

          gdb.puts('finish')
        else
          current_node.emit(html)
          current_node = nil
          gdb.puts('cont')
        end
      elsif /"finish" not meaningful in the outermost frame./ =~ lines
        gdb.puts('cont')
      else
        error = "Unknown message from GDB:\n#{lines}"
        STDERR.puts error
        raise error
      end
    end
  end

rescue
  error = "#{$!}\nBacktrace:\n#{$!.backtrace*"\n"}"
  exit_message = %Q(<p style="color:red">fugatrace BUG:<pre>#{CGI.escapeHTML(error)}</pre>)

  raise $!

ensure
  if current_node
    current_node.root.emit(html)
  end

  html.puts("</ul>")

  html.puts("<p>#{exit_message}")

  html.puts("<h1>Stopped points</h1>")

  by_breakpoints = []
  by_symbols = []
  stopped.each_with_index do |poses, i|
    next if !poses
    if breakpoints[i]
      by_breakpoints << [poses, i]
    else
      by_symbols << [poses, i]
    end
  end

  [['breakpoints', by_breakpoints, true],
   ['symbols', by_symbols, false]].each do |type, array, has_cmd|
    array = array.sort_by{|a|-a[0].size}
    html.puts("<p>by #{type}")
    html.puts(%Q(<table border="1"><tr><th>ID</th><th>Symbol</th><th>Location</th><th>Links</th>))
    if has_cmd
      html.puts "<th>Commands</th>"
    end
    html.puts "</tr>"

    array.each do |poses, i|
      pos_str = 'unused'
      if !poses.empty?
        pos_str = poses.map{|pos|
          %Q(<a href="#l#{pos}">#{pos}</a>)
        } * ', '
      end
      html.puts("<tr><td>#{i}</td><td>#{stop_functions[i]}</td><td>#{stop_positions[i]}</td><td>#{pos_str}</td>")
      if has_cmd
        html.puts("<td>#{breakpoints[i] * '<br>'}</td>")
      end
      html.puts("</tr>")
    end
    html.puts("</table>")
  end

  html.puts("</body></html>")

  html.close
  gdb.quit
end
