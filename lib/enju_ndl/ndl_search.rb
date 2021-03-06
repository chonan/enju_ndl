# -*- encoding: utf-8 -*-
module EnjuNdl
  module NdlSearch
    def self.included(base)
      base.extend ClassMethods
    end

    module ClassMethods
      def import_isbn(isbn)
        isbn = ISBN_Tools.cleanup(isbn)
        raise EnjuNdl::InvalidIsbn unless ISBN_Tools.is_valid?(isbn)

        manifestation = Manifestation.find_by_isbn(isbn)
        return manifestation if manifestation

        doc = return_xml(isbn)
        raise EnjuNdl::RecordNotFound unless doc
        #raise EnjuNdl::RecordNotFound if doc.at('//openSearch:totalResults').content.to_i == 0
        import_record(doc)
      end

      def import_record(doc)
        pub_date, language, nbn, ndc, isbn = nil, nil, nil, nil, nil

        publishers = get_publishers(doc).zip([]).map{|f,t| {:full_name => f, :full_name_transcription => t}}

        # title
        title = get_title(doc)

        # date of publication
        pub_date = doc.at('//dcterms:date').content.to_s.gsub(/\./, '-')
        unless pub_date =~  /^\d+(-\d{0,2}){0,2}$/
          pub_date = nil
        end

        language = get_language(doc)
        isbn = doc.at('./dc:identifier[@xsi:type="dcndl:ISBN"]').try(:content).to_s
        nbn = doc.at('//dcterms:identifier[@rdf:datatype="http://ndl.go.jp/dcndl/terms/JPNO"]').content
        classification_urls = doc.xpath('//dcterms:subject[@rdf:resource]').map{|subject| subject.attributes['resource'].value}
        if classification_urls
          ndc9_url = classification_urls.map{|url| URI.parse(url)}.select{|u| u.path.split('/').reverse[1] == 'ndc9'}.first
          if ndc9_url
            ndc = ndc9_url.path.split('/').last
          end
        end
        description = doc.at('//dcterms:abstract').try(:content)

        manifestation = nil
        Patron.transaction do
          publisher_patrons = Patron.import_patrons(publishers)
          language_id = Language.where(:iso_639_2 => language).first.id rescue 1

          manifestation = Manifestation.new(
            :original_title => title[:manifestation],
            :title_transcription => title[:transcription],
            # TODO: NDLサーチに入っている図書以外の資料を調べる
            #:carrier_type_id => CarrierType.where(:name => 'print').first.id,
            :language_id => language_id,
            :isbn => isbn,
            :pub_date => pub_date,
            :description => description,
            :nbn => nbn,
            :ndc => ndc
          )
          manifestation.publishers << publisher_patrons
          create_frbr_instance(doc, manifestation)
        end

        #manifestation.send_later(:create_frbr_instance, doc.to_s)
        return manifestation
      end

      def import_isbn!(isbn)
        manifestation = import_isbn(isbn)
        manifestation.save!
        manifestation
      end

      def create_frbr_instance(doc, manifestation)
        title = get_title(doc)
        creators = get_creators(doc)
        language = get_language(doc)
        subjects = get_subjects(doc)

        Patron.transaction do
          creator_patrons = Patron.import_patrons(creators)
          language_id = Language.where(:iso_639_2 => language).first.id rescue 1
          content_type_id = ContentType.where(:name => 'text').first.id rescue 1
          manifestation.creators << creator_patrons
          if defined?(Subject)
            subjects.each do |term|
              subject = Subject.where(:term => term).first
              manifestation.subjects << subject if subject
            end
          end
        end
      end

      def search_ndl(query, options = {})
        options = {:dpid => 'iss-ndl-opac', :item => 'any', :startrecord => 1, :per_page => 10, :raw => false}.merge(options)
        doc = nil
        results = {}
        startrecord = options[:startrecord].to_i
        if startrecord == 0
          startrecord = 1
        end
        url = "http://iss.ndl.go.jp/api/opensearch?dpid=#{options[:dpid]}&#{options[:item]}=#{URI.escape(query)}&cnt=#{options[:per_page]}&idx=#{startrecord}"
        if options[:raw] == true
          open(url).read
        else
          RSS::Rss::Channel.install_text_element("openSearch:totalResults", "http://a9.com/-/spec/opensearchrss/1.0/", "?", "totalResults", :text, "openSearch:totalResults")
          RSS::BaseListener.install_get_text_element "http://a9.com/-/spec/opensearchrss/1.0/", "totalResults", "totalResults="
          feed = RSS::Parser.parse(url, false)
        end
      end

      def normalize_isbn(isbn)
        if isbn.length == 10
          ISBN_Tools.isbn10_to_isbn13(isbn)
        else
          ISBN_Tools.isbn13_to_isbn10(isbn)
        end
      end

      def return_xml(isbn)
        rss = self.search_ndl(isbn, {:dpid => 'iss-ndl-opac', :item => 'isbn'})
        if rss.channel.totalResults.to_i == 0
          isbn = normalize_isbn(isbn)
          rss = self.search_ndl(isbn, {:dpid => 'iss-ndl-opac', :item => 'isbn'})
        end
        if rss.items.first
          doc = Nokogiri::XML(open("#{rss.items.first.link}.rdf").read)
        end
      end

      private
      def get_title(doc)
        title = {
          :manifestation => doc.xpath('//dc:title/rdf:Description/rdf:value').collect(&:content).join(' ').tr('ａ-ｚＡ-Ｚ０-９　', 'a-zA-Z0-9 ').squeeze(' '),
          :transcription => doc.xpath('//dc:title/dcndl:transcription').collect(&:content).join(' ').tr('ａ-ｚＡ-Ｚ０-９　', 'a-zA-Z0-9 ').squeeze(' '),
          :original => doc.xpath('//dcterms:alternative/rdf:Rescription/rdf:value').collect(&:content).join(' ').tr('ａ-ｚＡ-Ｚ０-９　', 'a-zA-Z0-9 ').squeeze(' ')
        }
      end

      def get_creators(doc)
        creators = []
        doc.xpath('//dcterms:creator/foaf:Agent').each do |creator|
          creators << {
            :full_name => creator.at('./foaf:name').content,
            :full_name_transcription => creator.at('./dcndl:transcription').try(:content)
          }
        end
        creators
      end

      def get_subjects(doc)
        subjects = []
        doc.xpath('//dcterms:subject/rdf:Description/rdf:value').each do |subject|
          subjects << subject.content.tr('ａ-ｚＡ-Ｚ０-９　‖', 'a-zA-Z0-9 ')
        end
        return subjects
      end

      def get_language(doc)
        # TODO: 言語が複数ある場合
        language = doc.xpath('//dcterms:language').first.content.downcase
      end

      def get_publishers(doc)
        publishers = []
        doc.xpath('//dcterms:publisher/foaf:Agent/foaf:name').each do |publisher|
          publishers << publisher.content.tr('ａ-ｚＡ-Ｚ０-９　‖', 'a-zA-Z0-9 ')
        end
        return publishers
      end
    end

    class AlreadyImported < StandardError
    end
  end
end
