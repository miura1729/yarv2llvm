#!/bin/ruby
#
#  LLVM level Post optimizer 
#
module YARV2LLVM
  class PostOptimizer
    DECL_FUNC_ATTR = {
      "declare i32 @rb_float_new(double)\n" => " readonly nounwind"
    }

    def optimize(llvmstr)
      res = ""
      funcstr = ""
      llvmstr.scan(/.*\n/).each do |fstr|
        if /^define/ =~ fstr then
          res << funcstr
          funcstr = fstr
        elsif /^}$/ =~ fstr then
          funcstr << fstr
          res << optimize_func(funcstr)
          funcstr = ""
        elsif /^declare / =~ fstr then
          attr = DECL_FUNC_ATTR[fstr].to_s
          funcstr << (fstr + attr)
        else
=begin
          if /call i32 @rb_float_new\(/ =~ fstr then
            fstr = fstr.sub(/call i32 @rb_float_new\(.*\)/, '\& nounwind readonly')
            p fstr
          end
=end
          funcstr << fstr
        end
      end
      res << funcstr
      res
    end

#  %80 = load i32* %50		; <i32> [#uses=1]
#  %81 = inttoptr i32 %80 to { { i32, i32 }, double }*		; <{ { i32, i32 }, double }*> [#uses=1]
#  %82 = getelementptr { { i32, i32 }, double }* %81, i64 0, i32 1		; <double*> [#uses=1]
#  %83 = load double* %82		; <double> [#uses=1]
    V2D_PATTERN = %r|
      \n
      \s+(\S+)\s=\sload\s\i32\*\s(\S+).*\n
      \s+(\S+)\s=\sinttoptr\s\S+\s\1\sto\s{\s{\si32,\si32\s},\sdouble\s}\*.*\n
      \s+(\S+)\s=\sgetelementptr\s{\s{\si32,\si32\s},\sdouble\s}\*\s\3,\si64\s0,\si32\s1.*\n
      \s+(\S+)\s=\sload\sdouble\*\s\4.*\n
    |x


    def optimize_func(funcstr)
      res = funcstr.dup
      funcstr.scan(V2D_PATTERN) do |n|
        d2v_pattern = /[ \t]+(\S+)\s=\scall\si32\s@rb_float_new\(double #{n[4]}\)/
        if d2v_pattern =~ funcstr then
          res.gsub!(d2v_pattern, "\t#{$1} = load i32* #{n[1]}")
        end
      end
      res
    end

  end
end

