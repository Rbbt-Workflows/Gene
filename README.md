Translate gene identifiers and mine PubMed literature for a gene, including LLM-based summarization and interaction extraction.

This workflow provides gene-centric utilities for translating gene identifiers, gathering PubMed literature linked to a gene via Entrez Gene and UniProt, and producing LLM-based summaries and interaction extraction from the retrieved literature.

The workflow is implemented as an EntityWorkflow over a Gene entity. A gene is provided as an identifier plus two common annotation inputs:

- format: how the identifier is expressed (default: "Associated Gene Name" which is how HGNC symbols are called). Generally you won't need to change it
- namespace: organism/identifier namespace (default: "Hsa/feb2014")

Most tasks can be used either from Ruby (as a library) or via the Scout/Rbbt REST layer, depending on how you deploy workflows.

Minimal Ruby usage example:

```ruby
Workflow.require_workflow "Gene"

gene = Gene.setup("TP53", format: "Associated Gene Name", namespace: "Hsa/feb2014")

entrez_id = gene.translate(target_format: "Entrez Gene ID").run
pmids     = gene.pmids(pmid_source: :both).run
summary   = gene.literature_summary.run
```

Notes and dependencies:

- Identifier translation relies on Organism identifiers and the underlying Rbbt identifier system.
- entrez_pmids uses Rbbt Entrez sources.
- uniprot_pmids calls the UniProt REST API and extracts PubMed cross-references.
- PubMed.get_article is called to prefetch/cache article metadata/abstracts for the returned PMIDs.
- literature_summary and interactions use an LLM endpoint named embed (via scout-ai). You must configure that endpoint in your Scout deployment.
- The rag task is an alias to the DocID workflow. This workflow declares Workflow.require_workflow "DocID"; you must have that workflow available.

# Tasks

## translate
Translate gene identifiers

Takes the current gene entity (as specified by the format and namespace annotation inputs) and converts it to the requested target format using the Rbbt identifier translation system.

The HGNC symbols are called "Associated Gene Name" which is a more general name for
gene symbols across all organisms.

Inputs:

- target_format: Format to which translate the gene identifier (default: "UniProt/SwissProt Accession")

Output:

- A string containing the translated identifier.

Example:

```ruby
gene = Gene.setup("TP53")

gene.translate(target_format: "Entrez Gene ID").run
```

## uniprot
Translate the gene identifier to a UniProt/SwissProt accession

Convenience alias for translate with target_format set to "UniProt/SwissProt Accession".

This task is useful as a building block for other tasks that need a UniProt accession, such as uniprot_pmids.

Example:

```ruby
Gene.setup("TP53").uniprot.run
```

## entrez
Translate the gene identifier to an Entrez Gene ID

Convenience alias for translate with target_format set to "Entrez Gene ID".

Example:

```ruby
Gene.setup("TP53").entrez.run
```

## desc
Render a human-oriented description page for the gene

Returns a rendered description of the gene using a HAML template (share/haml/desc.haml). In the current implementation the template is minimal and renders the entity name and long name.

Implementation detail:

- This task calls the internal render helper, which uses the current task name as the template name unless overridden.
- The workflow sets extension :haml before defining this task; depending on your deployment this may affect how the result is served through the REST layer.

## entrez_pmids
Collect PubMed IDs linked to the gene through Entrez Gene

Resolves the gene to an Entrez Gene ID and then queries Entrez mappings to retrieve PubMed IDs associated with that gene for the organism implied by the namespace.

The task also calls PubMed.get_article(pmids) to prefetch/cache the articles.

Output:

- An array of document identifiers in the form PMID:<pmid>:abstract.

Implementation notes:

- The organism taxon is derived by mapping Organism.scietific_name(namespace) to an Entrez tax ID using a local index stored under Rbbt.share.databases.entrez.tax_ids.
- The PubMed identifiers are obtained from Entrez.entrez2pubmed(tax)[entity.entrez].

## uniprot_pmids
Collect PubMed IDs linked to the gene through UniProt references

Resolves the gene to a UniProt/SwissProt accession, downloads the UniProt JSON record, and extracts PubMed cross-references from the references section.

The task also calls PubMed.get_article(pmids) to prefetch/cache the articles.

Output:

- An array of document identifiers in the form PMID:<pmid>:abstract.

Implementation notes:

- UniProt is queried using https://rest.uniprot.org/uniprotkb/<accession>?format=json.
- PubMed IDs are extracted from citationCrossReferences entries with database equal to PubMed.

## pmids
Collect PubMed IDs for the gene from one or both sources

Combines the PMID lists from entrez_pmids and uniprot_pmids.

Inputs:

- pmid_source: where to obtain PMIDs (default: both). Allowed values are both, entrez, uniprot.

Output:

- An array of document identifiers in the form PMID:<pmid>:abstract.

Implementation notes:

- Dependency selection is dynamic: depending on pmid_source the workflow declares dependencies on entrez_pmids, uniprot_pmids, or both.
- The task merges dependency results by loading each dependency and concatenating arrays.

Example:

```ruby
gene = Gene.setup("TP53")

gene.pmids(pmid_source: :entrez).run
```

## rag
Run retrieval augmented generation over the gene-linked PubMed documents

Convenience alias to DocID rag, using the PMID list produced by the pmids task as the document list.

This task delegates its implementation to the DocID workflow, so the exact output depends on the DocID rag task definition.

Implementation notes:

- This is declared as list_task_alias :rag, DocID, :rag, list: :pmids.
- The workflow also declares dep :pmids, compute: :produce and dep :rag, compute: :produce to ensure upstream production when building composite jobs.

## literature_summary
Summarize the gene literature using an LLM

Builds a text corpus from the documents selected by rag, fetches their text through DocID, and asks an LLM to summarize the combined content.

Output:

- A text summary intended to be markdown (the workflow sets extension :md before this task).

Implementation notes:

- The workflow dynamically creates dependencies on DocID text jobs for each document id produced by rag.
- It concatenates the loaded document texts (one per line) and sends them to LLM.ask with a prompt of the form Summarize this text followed by the combined text.
- The response is post-processed by splitting on </think> and taking the final segment.
- The LLM endpoint used is embed; this must exist in your Scout LLM configuration.

## interactions
Extract protein-protein interactions mentioned in the summarized literature

Uses an LLM to extract a tab-separated interaction list from the summarized literature.

Output:

- An array of lines, one interaction per line, in the form protein1\tprotein2\ttype.

Implementation notes:

- The prompt requests that all gene and protein mentions be translated into HGNC format for human.
- The task depends on literature_summary, but the current code loads text using step(:uniprot_summary). If uniprot_summary is not defined in your deployment, this task will fail until the reference is updated to use the intended upstream task output.
- The LLM endpoint used is embed; the output is split on </think> and then split into lines.
