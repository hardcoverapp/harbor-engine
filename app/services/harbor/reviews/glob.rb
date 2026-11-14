module Harbor
  module Reviews
    # Path globs as people write them in a check's watch_paths:
    #   **/   any number of directories (including none)
    #   **    anything, across directories
    #   *     anything within one path segment
    #   ?     one character within a segment
    #   {a,b} alternatives
    module Glob
      module_function

      def match?(glob, path) = regexp(glob).match?(path.to_s)

      def regexp(glob)
        @cache ||= {}
        @cache[glob] ||= begin
          out = +"\\A"
          s = glob.to_s
          i = 0
          while i < s.length
            c = s[i]
            if s[i, 3] == "**/"
              out << "(?:.*/)?"; i += 3
            elsif s[i, 2] == "**"
              out << ".*"; i += 2
            elsif c == "*"
              out << "[^/]*"; i += 1
            elsif c == "?"
              out << "[^/]"; i += 1
            elsif c == "{"
              close = s.index("}", i)
              if close
                out << "(?:" << s[(i + 1)...close].split(",").map { |p| Regexp.escape(p) }.join("|") << ")"
                i = close + 1
              else
                out << "\\{"; i += 1
              end
            else
              out << Regexp.escape(c); i += 1
            end
          end
          Regexp.new(out << "\\z")
        end
      end
    end
  end
end
