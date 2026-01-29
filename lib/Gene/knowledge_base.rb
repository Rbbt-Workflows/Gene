require 'scout/knowledge_base'
require 'rbbt/sources/signor'

module Gene
  self.knowledge_base = KnowledgeBase.new Rbbt.var.Gene.knowledge_base
  #self.knowledge_base.register :signor, Signor.protein_protein, source: "=>Associated Gene Name", target: "=>Associated Gene Name", identifiers: Organism.identifiers("NAMESPACE"), namespace: "Hsa/feb2014"
end


