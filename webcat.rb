#!/usr/local/bin/ruby
# -*- coding: utf-8 -*-

$:.unshift "."

require "net/http"
require "net/https"
#require "pp"
require "erb"
require "cgi"
require "nkf"
require "kconv"
require "yaml"

require "rubygems"
require "libxml"

module Webcat
   VERSION = '0.1'
   BASE_URI = 'http://webcat.jp'
   USER_AGENT = "Webcat/#{ VERSION }; #{ BASE_URI }"
   MAX_PAGE = 19 # ページネイションに表示されるアイテム数

   # Supports redirect
   def http_get( uri, limit = 10 )
      #STDERR.puts uri.to_s
      raise "Too many redirects: #{ uri }" if limit < 0
      http_proxy = ENV[ "http_proxy" ]
      proxy, proxy_port = nil
      if http_proxy
         proxy_uri = URI.parse( http_proxy )
         proxy = proxy_uri.host
         proxy_port = proxy_uri.port
      end
      http = Net::HTTP.Proxy( proxy, proxy_port ).new( uri.host, uri.port )
      http.use_ssl = true if uri.scheme == "https"
      http.start do |http|
         response, = http.get( uri.request_uri, { 'User-Agent'=>USER_AGENT } )
         #if response.code !~ /^2/
         #   response.each do |k,v|
         #      p [ k, v ]
         #   end
         #end
         case response
         when Net::HTTPSuccess
            response
         when Net::HTTPRedirection
            redirect_uri = URI.parse( response['Location'] )
            STDERR.puts "redirect to #{ redirect_uri } (#{limit})"
            http_get( uri + redirect_uri, limit - 1 )
         else
            response.error!
         end
      end
   end

   CINIIBOOKS_BASEURI = "http://ci.nii.ac.jp/books/opensearch/search"
   # CiNii Opensearch API
   def ciniibooks_search( keyword, opts = {} )
      q = URI.escape( keyword )
      cont = nil
      # TODO: Atom/RSSの双方を対象にできるようにすること（現状は Atom のみ）
      opts[ :format ] = "atom"
      if not opts.empty?
         opts_s = opts.keys.map do |e|
            "#{ e }=#{ URI.escape( opts[e].to_s ) }"
         end.join( "&" )
      end
      raise "CiNii AppID is not available in configuration file." if @conf[ "cinii_appid" ].nil? or  @conf[ "cinii_appid" ].empty?
      opensearch_uri = URI.parse( "#{ CINIIBOOKS_BASEURI }?q=#{ q }&appid=#{ @conf["cinii_appid"] }&#{ opts_s }" )
      #p opensearch_uri
      response = http_get( opensearch_uri )
      cont = response.body
      data = {}
      parser = LibXML::XML::Parser.string( cont )
      doc = parser.parse
      # ref. http://ci.nii.ac.jp/info/ja/if_opensearch.html
      data[ :q ] = keyword
      data[ :link ] = doc.find( "//atom:id", "atom:http://www.w3.org/2005/Atom" )[0].content.gsub( /&(format=atom|appid=#{ @conf["cinii_appid"] })\b/, "" )
      data[ :totalResults ] = doc.find( "//opensearch:totalResults" )[0].content.to_i
      if data[ :totalResults ] > 0
         data[ :itemsPerPage ] = doc.find( "//opensearch:itemsPerPage" )[0].content.to_i
      end
      entries = doc.find( "//atom:entry", "atom:http://www.w3.org/2005/Atom" )
      data[ :entries ] = []
      entries.each do |e|
         title = e.find( "./atom:title", "atom:http://www.w3.org/2005/Atom" )[0].content
         url = e.find( "./atom:id", "atom:http://www.w3.org/2005/Atom" )[0].content
         author = e.find( ".//atom:author/atom:name", "atom:http://www.w3.org/2005/Atom" ).to_a.map{|name|
            a = name.content
            #p a
            /^\s*\W/.match( a ) ? a.gsub( /\s*,\s*/, " " ) : a
         }.join( "; " )
         publisher = e.find( "./dc:publisher", "dc:http://purl.org/dc/elements/1.1/" )[0]
         if publisher
            publisher = publisher.content
         else
            publisher = nil
         end
         pubname = e.find( "./prism:publicationName", "prism:http://prismstandard.org/namespaces/basic/2.0/" )[0]
         if pubname.nil?
            pubname = e.find( "./dc:publisher", "dc:http://purl.org/dc/elements/1.1/" )[0]
            pubname = pubname.content if pubname
         else
            pubname = pubname.content
         end
         pubdate = e.find( "./prism:publicationDate", "prism:http://prismstandard.org/namespaces/basic/2.0/" )[0] #.content
         pubdate = pubdate.nil? ? "" : pubdate.content
         description = e.find( "./atom:content", "atom:http://www.w3.org/2005/Atom" )[0]
         description = description.nil? ? "" : description.content
         data[ :entries ] << {
            :title => title,
            :url => url,
            :author => author,
            :publicationName => pubname,
            :publicationDate => pubdate,
            :publisher => publisher,
            :description => description,
         }
      end
      data
   end

   class NoHitError < Exception; end
   class NoKeywordExtractedError < Exception; end
   class UnsupportedURI < Exception; end
   class Message < Hash
      ERROR_MESSAGE = {
         "Webcat::NoHitError" => "関連する文献を見つけることができませんでした。",
      }
      def initialize
         set = ERROR_MESSAGE.dup
      end
   end

   class App
      attr_reader :format, :count, :page
      def initialize( cgi, conf )
         @cgi = cgi
         @conf = conf
         @format = @cgi.params["format"][0] || "html"
         @count = @cgi.params["count"][0].to_i
         @count = 200 if @count < 1
         @page = @cgi.params["page"][0].to_i
         @type = case @cgi.params["db"][0]
                 when "tosho"
                    1
                 when "zasshi"
                    2
                 else
                    nil
                 end
         @author = @cgi.params["auth"][0]
         @publisher = @cgi.params["pub"][0]
         @year = @cgi.params["year"][0].to_i
         @year = nil if @year == 0
         @isbn = @cgi.params["isbn"][0]
	 if @isbn
         @isbn = @isbn.gsub( /[^0-9Xx]/, "" )
         if @isbn.length == 8
            @issn = @isbn.dup
            @isbn = nil
         else
            @issn = nil
         end
	 end
         @callback = @cgi.params["callback"][0]

         raise( "Crawler access is limited to the first page." ) if @page > 0 and @cgi.user_agent =~ /bot|slurp|craw|spid/i
      end

      def query?
         @cgi.params["title"][0]
      end

      include Webcat
      def output( prefix, data = {} )
         #STDERR.puts data.inspect
         case format
         when "html"
            print @cgi.header
            if query? and not data.has_key?( :error )
               #print eval_rhtml( "./#{ prefix }.rhtml", binding )
               data = ciniibooks_search( @cgi["title"], {
                                            :type  => @type,
                                            :count => @count,
                                            :author => @author,
                                            :publisher => @publisher,
                                            :year_from => @year,
                                            :year_to => @year,
                                            :isbn => @isbn,
                                            :issn => @issn,
                                            :sortorder => 5, # # of holding libs.
                                         } )
               #print data.inspect
               print eval_rhtml( "./results.rhtml", binding )
            else
               print eval_rhtml( "./top.rhtml", binding )
            end
         when "json"
            print @cgi.header "application/json"
            result = JSON::generate( data )
            if @callback and @callback =~ /^\w+$/
               result = "#{ @callback }(#{ result })"
            end
            print result
         else
            raise "unknown format specified: #{ format }"
         end
      end

      include ERB::Util
      def eval_rhtml( fname, binding )
         rhtml = open( fname ){|io| io.read }
         result = ERB::new( rhtml, $SAFE, "<>" ).result( binding )
      end
   end
end

if $0 == __FILE__
   @cgi = CGI.new
   begin
      conf = YAML.load( open( "webcat.conf" ) )
      app = Webcat::App.new( @cgi, conf )
      data = {}
      app.output( "cinii", data )
   rescue Exception
      if @cgi then
         print @cgi.header( 'status' => CGI::HTTP_STATUS['SERVER_ERROR'], 'type' => 'text/html' )
      else
         print "Status: 500 Internal Server Error\n"
         print "Content-Type: text/html\n\n"
      end
      puts "<h1>500 Internal Server Error</h1>"
      puts "<pre>"
      puts CGI::escapeHTML( "#{$!} (#{$!.class})" )
      puts ""
      puts CGI::escapeHTML( $@.join( "\n" ) )
      puts "</pre>"
      puts "<div>#{' ' * 500}</div>"
   end
end
