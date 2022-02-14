class VocabularyController < ApplicationController
  before_action :verify_permission, :only => [:new, :edit, :create, :update]

  def index
    identifier = params[:id]
    #@vocabulary = Vocabulary.find_by(identifier: identifier)
    #@terms = Term.find_with_conditions(@vocabulary.solr_model, q: "*:*", rows: '10000', fl: 'id,prefLabel_tesim' )
    #@terms = @terms.sort_by { |term| term["prefLabel_tesim"].first.downcase }

    @terms = Term.where(vocabulary_identifier: identifier, visibility: 'visible').order("lower(pref_label) ASC")

    respond_to do |format|
      format.html
      format.nt { render body: Term.all_terms_full_graph(@terms).dump(:ntriples), :content_type => "application/n-triples" }
      format.jsonld { render body: Term.all_terms_full_graph(@terms).dump(:jsonld, standard_prefixes: true), :content_type => 'application/ld+json' }
      format.ttl { render body: Term.all_terms_full_graph(@terms).dump(:ttl, standard_prefixes: true), :content_type => 'text/turtle' }
      format.csv { send_data Term.csv_download(@terms), filename: "Homosaurus_#{identifier}_#{Date.today}.csv" }
    end
  end

  def show
    @homosaurus_obj = Term.find_by(vocabulary_identifier: params[:vocab_id], identifier: params[:id])
    @homosaurus = Term.find(@homosaurus_obj.identifier)

    # For terms  that are combined / replaced
    if @homosaurus_obj.visibility == "redirect" and @homosaurus_obj.is_replaced_by.present?
      redirect_to @homosaurus_obj.is_replaced_by
    end

    respond_to do |format|
      format.html
      format.nt { render body: @homosaurus_obj.full_graph.dump(:ntriples), :content_type => "application/n-triples" }
      format.jsonld { render body: @homosaurus_obj.full_graph.dump(:jsonld, standard_prefixes: true), :content_type => 'application/ld+json' }
      format.json { render body: @homosaurus_obj.full_graph_expanded_json, :content_type => 'application/json' }
      format.ttl { render body: @homosaurus_obj.full_graph.dump(:ttl, standard_prefixes: true), :content_type => 'text/turtle' }
    end
  end

  def search
    @vocabulary_identifier = params[:id]
    @vocabulary = Vocabulary.find_by(identifier: @vocabulary_identifier)
    if params[:q].present?
      opts = {}
      opts[:q] = params[:q]
      opts[:pf] = 'prefLabel_tesim'
      opts[:qf] = 'prefLabel_tesim altLabel_tesim description_tesim identifier_tesim'
      opts[:fl] = 'id,identifier_ssi,prefLabel_tesim, altLabel_tesim, description_tesim, issued_dtsi, modified_dtsi, exactMatch_tesim, closeMatch_tesim, broader_ssim, narrower_ssim, related_ssim, isReplacedBy_ssim, replaces_ssim'
      opts[:fq] = "active_fedora_model_ssi:#{@vocabulary.solr_model}"
      response = DSolr.find(opts)
      docs = response
      @terms = Term.where(pid: docs.pluck("id"), visibility: 'visible')

      respond_to do |format|
        format.html
        format.nt { render body: Term.all_terms_full_graph(@terms).dump(:ntriples), :content_type => "application/n-triples" }
        format.jsonld { render body: Term.all_terms_full_graph(@terms).dump(:jsonld, standard_prefixes: true), :content_type => 'application/ld+json' }
        format.ttl { render body: Term.all_terms_full_graph(@terms).dump(:ttl, standard_prefixes: true), :content_type => 'text/turtle' }
      end
    end
  end

  def new
    @vocab_id = params[:vocab_id]
    @term = Term.new
    term_query = Term.where(vocabulary_identifier: params[:vocab_id]).order("lower(pref_label) ASC")
    @all_terms = []
    term_query.each { |term| @all_terms << [term.identifier + " (" + term.pref_label + ")", term.uri] }
  end

  def create
    ActiveRecord::Base.transaction do
      @vocabulary = Vocabulary.find_by(identifier: "v3")
      @term = Term.new
      # Fix the below
      numeric_identifier = Term.mint(vocab_id: "v3")
      identifier = "homoit" + numeric_identifier.to_s.rjust(7, '0')

      @term.numeric_pid = numeric_identifier
      @term.identifier = identifier
      @term.pid = "homosaurus/v3/#{identifier}"
      @term.uri = "https://homosaurus.org/v3/#{identifier}"
      @term.vocabulary_identifier = "v3"
      @term.vocabulary = @vocabulary
      @term.visibility = "visible"
      @term.manual_update_date = Time.now
      preflbl = params[:term][:pref_label_language][0].split('@')[0]
      preflbl_language = params[:term][:pref_label_language][0]
      if preflbl_language.include?('@')
        lang_check = preflbl_language.split('@').last
        unless lang_check == 'en-GB' || lang_check == 'en-US' || ISO_639.find_by_code(lang_check).present?
          preflbl_language = preflbl
        end
      end
      @term.pref_label = preflbl
      @term.pref_label_language = preflbl_language

      @term.update(term_params)
      language_labels = []
      params[:term][:labels_language].each do |lbl|
        if lbl.include?('@')
          lang_check = lbl.split('@').last
          if lang_check == 'en-GB' || lang_check == 'en-US' || ISO_639.find_by_code(lang_check).present?
            language_labels << lbl
          end
        end
      end
      @term.labels_language = language_labels
      @term.labels = language_labels.map { |lbl| lbl.split('@')[0]}

      alt_labels_language = []
      params[:term][:alt_labels_language].each do |lbl|
        if lbl.include?('@')
          lang_check = lbl.split('@').last
          if lang_check == 'en-GB' || lang_check == 'en-US' || ISO_639.find_by_code(lang_check).present?
            alt_labels_language << lbl
          end
        end
      end
      @term.alt_labels_language = alt_labels_language
      @term.alt_labels = alt_labels_language.map { |lbl| lbl.split('@')[0]}

      @term.save

      if params[:term][:broader].present?
        params[:term][:broader].each do |broader|
          if broader.present?
            #broader = broader.split("(").last[0..-1]
            broader_object = Term.find_by(uri: broader)
            @term.broader = @term.broader + [broader_object.uri]
            broader_object.narrower = broader_object.narrower + [@term.uri]
            broader_object.save
          end
        end
      end

      if params[:term][:narrower].present?
        params[:term][:narrower].each do |narrower|
          if narrower.present?
            #narrower = narrower.split("(").last[0..-1]
            narrower_object = Term.find_by(uri: narrower)
            @term.narrower = @term.narrower + [narrower_object.uri]
            narrower_object.broader = narrower_object.broader + [@term.uri]
            narrower_object.save
          end

        end
      end

      if params[:term][:related].present?
        params[:term][:related].each do |related|
          if related.present?
            #related = related.split("(").last[0..-1]
            related_object = Term.find_by(uri: related)
            @term.related = @term.related + [related_object.uri]
            related_object.related = related_object.related + [@term.uri]
            related_object.save
          end

        end
      end

      if @term.save
        redirect_to vocabulary_show_path(vocab_id: "v3", :id => @term.identifier)
      else
        redirect_to vocabulary_term_new_path(vocab_id: "v3")
      end
    end
  end

  def edit
    @vocab_id = params[:vocab_id]
    @term = Term.find_by(vocabulary_identifier: @vocab_id, identifier: params[:id])
    term_query = Term.where(vocabulary_identifier: params[:vocab_id]).order("lower(pref_label) ASC")
    @all_terms = []
    term_query.each { |term| @all_terms << [term.identifier + " (" + term.pref_label + ")", term.uri] }
  end

  def set_match_relationship(form_fields, key)
    form_fields[key.to_sym].each_with_index do |s, index|
      if s.present?
        form_fields[key.to_sym][index] = s.split('(').last
        form_fields[key.to_sym][index].gsub!(/\)$/, '')
      end
    end
    if form_fields[key.to_sym][0].present?
      @term.send("#{key}=", form_fields[key.to_sym].reject { |c| c.empty? })
    elsif @term.send(key).present?
      @term.send("#{key}=", [])
    end
  end

  # FIX the related stuff not needing identifiers for value
  def update
    if !params[:term][:identifier].match(/^[0-9a-zA-Z_\-+]+$/) || params[:term][:identifier].match(/ /)
      redirect_to vocabulary_show_path(vocab_id: "v3", id: params[:id]), notice: "Please use camel case for identifier like 'discrimationWithAbleism'... do not use spaces. Contact K.J. if this is seen for some other valid entry."
    else
      ActiveRecord::Base.transaction do
        @term = Term.find_by(vocabulary_identifier: "v3", identifier: params[:id])

        pid = "homosaurus/v3/#{params[:term][:identifier]}"
        pid_original = @term.pid

        #FIXME: Only do this if changed...
        @term.broader.each do |broader|
          #broader = broader.split("(").last[0..-1]
          hier_object = Term.find_by(uri: broader)
          hier_object.narrower.delete(@term.uri)
          hier_object.save
        end


        @term.narrower.each do |narrower|
          #narrower = narrower.split("(").last[0..-1]
          hier_object = Term.find_by(uri: narrower)
          hier_object.broader.delete(@term.uri)
          hier_object.save
        end


        @term.related.each do |related|
          #related = related.split("(").last[0..-1]
          hier_object = Term.find_by(uri: related)
          hier_object.related.delete(@term.uri)
          hier_object.save
        end
        #@term.reload

        @term.broader = []
        @term.narrower = []
        @term.related = []

        @term.pid = pid
        @term.uri = "https://homosaurus.org/v3/#{params[:term][:identifier]}"
        @term.identifier = params[:term][:identifier]

        set_match_relationship(params[:term], "exact_match_lcsh")
        set_match_relationship(params[:term], "close_match_lcsh")

        preflbl = params[:term][:pref_label_language][0].split('@')[0]
        preflbl_language = params[:term][:pref_label_language][0]
        if preflbl_language.include?('@')
          lang_check = preflbl_language.split('@').last
          unless lang_check == 'en-GB' || lang_check == 'en-US' || ISO_639.find_by_code(lang_check).present?
            preflbl_language = preflbl
          end
        end
        @term.pref_label = preflbl
        @term.pref_label_language = preflbl_language

        @term.update(term_params)
        language_labels = []
        params[:term][:labels_language].each do |lbl|
          if lbl.include?('@')
            lang_check = lbl.split('@').last
            if lang_check == 'en-GB' || lang_check == 'en-US' || ISO_639.find_by_code(lang_check).present?
              language_labels << lbl
            end
          end
        end
        @term.labels_language = language_labels
        @term.labels = language_labels.map { |lbl| lbl.split('@')[0]}

        alt_labels_language = []
        params[:term][:alt_labels_language].each do |lbl|
          if lbl.include?('@')
            lang_check = lbl.split('@').last
            if lang_check == 'en-GB' || lang_check == 'en-US' || ISO_639.find_by_code(lang_check).present?
              alt_labels_language << lbl
            end
          end
        end
        @term.alt_labels_language = alt_labels_language
        @term.alt_labels = alt_labels_language.map { |lbl| lbl.split('@')[0]}

        @term.save

        # FIXME: DO THIS BETTER
        if params[:term][:broader].present?
          params[:term][:broader].each do |broader|
            if broader.present?
              broader_object = Term.find_by(uri: broader)
              @term.broader = @term.broader + [broader_object.uri]
              broader_object.narrower = broader_object.narrower + [@term.uri]
              broader_object.save
            end
          end
        end

        if params[:term][:narrower].present?
          params[:term][:narrower].each do |narrower|
            if narrower.present?
              narrower_object = Term.find_by(uri: narrower)
              @term.narrower = @term.narrower + [narrower_object.uri]
              narrower_object.broader = narrower_object.broader + [@term.uri]
              narrower_object.save
            end

          end
        end

        if params[:term][:related].present?
          params[:term][:related].each do |related|
            if related.present?
              related_object = Term.find_by(uri: related)
              @term.related = @term.related + [related_object.uri]
              related_object.related = related_object.related + [@term.uri]
              related_object.save
            end

          end
        end


        if @term.save
          #flash[:success] = "HomosaurusV3 term was updated!"
          if pid != pid_original
            DSolr.delete_by_id(pid_original)
          end
          redirect_to vocabulary_show_path(vocab_id: "v3",  id: @term.identifier), notice: "HomosaurusV3 term was updated!"
        else
          redirect_to vocabulary_show_path(vocab_id: "v3",  id: @term.identifier), notice: "Failure! Term was not updated."
        end
      end
    end
  end

  def destroy

    @homosaurus = HomosaurusV3Subject.find(params[:id])

    @homosaurus.broader.each do |broader|
      hier_object = HomosaurusV3Subject.find_by(identifier: broader)
      hier_object.narrower.delete(@homosaurus.identifier)
      hier_object.save
    end


    @homosaurus.narrower.each do |narrower|
      hier_object = HomosaurusV3Subject.find_by(identifier: narrower)
      hier_object.broader.delete(@homosaurus.identifier)
      hier_object.save
    end


    @homosaurus.related.each do |related|
      hier_object = HomosaurusV3Subject.find_by(identifier: related)
      hier_object.related.delete(@homosaurus.identifier)
      hier_object.save
    end
    @homosaurus.reload

    @homosaurus.broader = []
    @homosaurus.narrower = []
    @homosaurus.related = []

    @homosaurus.destroy
    redirect_to homosaurus_v3_index_path, notice: "HomosaurusV3 term was deleted!"
  end


  def term_params
    params.require(:term).permit(:identifier, :description, :exactMatch, :closeMatch)
  end

  def verify_permission
    if !current_user.present? || (!current_user.admin? && !current_user.superuser? && !current_user.contributor?)
      redirect_to root_path
    end
  end

end
