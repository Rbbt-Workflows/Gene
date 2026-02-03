require 'scout-ai'
require "rbbt/rest/common/locate"
require "rbbt/rest/common/render"
require "rbbt/sources/organism"
require "rbbt/sources/entrez"
require "rbbt/sources/uniprot"
require "rbbt/document"
require "rbbt/document/corpus"
require "rbbt/document/corpus/pubmed"

Workflow.require_workflow "DocID"

module Gene
  extend EntityWorkflow
  include Entity::Identified

  add_identifiers Organism.identifiers("NAMESPACE"), "Associated Gene Name"

  annotation_input :format, :string, "Format in which the gene is specified", "Associated Gene Name" 
  annotation_input :namespace, :string, "Namespace of the entity", "Hsa/feb2014"

  helper :layout do
    nil
  end

  helper :render do |entity,template=nil|
    template ||= task_name
    entity = entity.extend RbbtRESTHelpers
    entity.define_singleton_method(:user){}
    entity.render Rbbt.share.haml[template].find_with_extension('haml'), inputs.to_hash.merge(entity: entity), layout
  end

  desc "Translate gene identifiers"
  input :target_format, :string, "Format to which translate the gene identifier", "UniProt/SwissProt Accession"
  entity_task translate: :string do |target_format|
    begin
      entity.to target_format
    rescue => e
      begin
        entity.format = nil
        entity.to target_format
      rescue
        raise e
      end
    end
  end

  entity_task_alias :uniprot, Gene, :translate, target_format: "UniProt/SwissProt Accession"

  entity_task_alias :entrez, Gene, :translate, target_format: "Entrez Gene ID"

  extension :haml
  entity_task desc: :text do
    render entity
  end

  entity_task entrez_pmids: :array do
    entrez = begin
               entity.entrez
             rescue => e
               begin
                 entity.format = nil
                 entity.entrez
               rescue
                 raise e
               end
             end
    raise "Could not find entrez code for #{entity}" if entrez.nil?
    entrez = Gene.setup entrez, format: "Entrez Gene ID", namespace: entity.namespace
    index = Rbbt.share.databases.entrez.tax_ids.index target: "Entrez Tax ID", persist: true
    tax = index[Organism.scietific_name(entrez.namespace)]
    pmids = Entrez.entrez2pubmed(tax)[entrez]
    PubMed.get_article(pmids)
    pmids.collect{|id| ["PMID", id, :abstract] * ":" }
  end

  entity_task :uniprot_pmids => :array do
    uniprot = begin
                entity.to("UniProt/SwissProt Accession")
              rescue => e
                begin
                  entity.format = nil
                  entity.to("UniProt/SwissProt Accession")
                rescue
                  raise e
                end
              end
    json = JSON.parse(Open.read("https://rest.uniprot.org/uniprotkb/#{uniprot}?format=json"))
    IndiferentHash.setup(json)
    pmids = json.dig("references").
      inject([]){|acc,e| 
        begin 
          acc += e.dig("citation", "citationCrossReferences")  || []
        rescue a
          cc
        end
      }.
      select{|e| e["database"] == "PubMed"}.
      collect{|e| e["id"]}

      PubMed.get_article(pmids)
      pmids.collect{|id| ["PMID", id, :abstract] * ":" }
  end

  input :pmid_source, :select, "Where to get the PMIDs for a gene", :both, select_options: %w(both entrez uniprot)
  dep :entrez_pmids do |jobname,options|
    case options[:pmid_source].to_sym
    when :both
      [{task: :entrez_pmids}, {task: :uniprot_pmids}]
    when :entrez
      {task: :entrez_pmids}
    when :uniprot
      {task: :uniprot_pmids}
    end
  end
  entity_task pmids: :array do |source|
    dependencies.flatten.inject(nil){|acc,dep| 
      acc = acc.nil? ? dep.load : acc + dep.load
    }
  end

  dep :pmids, compute: :produce
  list_task_alias :rag, DocID, :rag, list: :pmids

  dep :rag, compute: :produce
  dep DocID, :text do |jobname,options,dependencies|
    dependencies.flatten.first.run.collect do |docid|
      {jobname: docid, inputs:options }
    end
  end
  extension :md
  property_task :literature_summary => :text do |uniprot_abstracts|
    Step.wait_for_jobs dependencies
    text = dependencies[1..-1].collect(&:load) * "\n"
    endpoint = config(:endpoint)
    response = LLM.ask "Summarize this text:\n[[#{text}]]", endpoint: endpoint
    response.split("</think>").last.strip
  end

  dep :literature_summary
  property_task :interactions => :array do
    prompt =<<-EOF
Extract from this text a list of interactions between proteins in the format:
<protein1>\\t<protein2>\\t<type of interaction>
The type of interaction is a word like inhibits, acetylates, binds, represses, etc.
Only reply with the interactions, one by line.
Also, translate all gene and protein mentions into HGNC format for human
    EOF
    text = step(:uniprot_summary).load

    endpoint = config(:endpoint)
    response = LLM.ask "#{prompt}:\n[[#{text}]]", endpoint: endpoint
    response.split("</think>").last.split("\n")
  end

  export :interactions, :literature_summary, :rag
end

require "Gene/knowledge_base"

Workflow.main = Gene
