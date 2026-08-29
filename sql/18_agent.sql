/* ============================================================================
   18_agent.sql  —  APP.RM_COPILOT, the relationship manager's copilot
   ----------------------------------------------------------------------------
   M9 step 3, and the last object in the build. Everything before this produced
   a capability; this is the thing a person talks to.

   Four tools, which is the whole design:

     portfolio_analytics   Cortex Analyst on GOLD.SV_CUSTOMER_360
                           "how many / which customers / trend / total"
     interaction_search    Cortex Search on APP.SEARCH_INTERACTIONS
                           "what did they actually say"
     product_terms         Cortex Search on APP.SEARCH_PRODUCT_DOCS
                           "is this allowed / what are the terms"
     next_best_actions     APP.GET_NEXT_BEST_ACTIONS
                           "what should I do next"

   Cost: ZERO CREDITS TO CREATE. Every question asked of it afterwards costs
   orchestration tokens plus whichever tools it calls, and a Cortex Analyst call
   bills 0.067 credits per message regardless of how simple the question is. That
   rate is the dominant cost of operating this agent and is why the orchestration
   instructions below tell it not to call Analyst for a question about one named
   customer -- that is not only a routing rule, it is the cost control.

   ----------------------------------------------------------------------------
   WHY FOUR TOOLS AND NOT TWO
   ----------------------------------------------------------------------------
   PROJECT_BRIEF M9 scoped this as Analyst plus one search service plus
   data_to_chart. That is a reporting assistant. It answers "how many customers
   are in arrears" and it cannot answer "what should I do about Mr Malhotra",
   which is the only question a relationship manager actually has.

   The two additions each close a specific gap:

     APP.SEARCH_PRODUCT_DOCS turns an opinion into an argument. "Offer them a
     Platinum card" is a view. "Offer them a Platinum card, and
     BNK_CARD_PLAT#ELIG-01 is the clause that says a 34-year-old in income band
     4 qualifies" is a citation somebody can check.

     APP.GET_NEXT_BEST_ACTIONS is the only tool that can answer the actual
     question, and -- more importantly -- the only one that returns what was
     SUPPRESSED. The other three cannot see suppression at all. An agent that
     recommends from search results and portfolio metrics is an agent that will
     cheerfully propose a loan to somebody in arrears, because nothing in what it
     was handed said not to.

   data_to_chart is deliberately NOT attached. It renders a chart from a tool
   result, and every chart-shaped question here is a portfolio question that
   Analyst already answers as a table. Adding it would widen the tool surface
   with no question it uniquely answers, against the guidance to give an agent
   only the tools it needs.

   ----------------------------------------------------------------------------
   CONFIGURED AROUND THE PHASE-6 RETRIEVAL FINDINGS
   ----------------------------------------------------------------------------
   sql/10 measured three properties of APP.SEARCH_INTERACTIONS that between them
   rule out the obvious way to configure a search tool.

   1. THE COSINE SCORES DO NOT CARRY A PORTABLE MEANING. So there is no absolute
      score floor anywhere in this spec, and the tool description tells the agent
      to judge relevance by RANK and by the gap between consecutive scores -- the
      score-cliff pattern -- rather than by a threshold. A floor tuned on one
      query is miscalibrated on the next, and the failure mode is silent: it
      returns nothing and the agent says the customer never mentioned it.

   2. THE CORPUS IS TOP-HEAVY -- 42% of it is one artefact type. Unfiltered
      semantic search over it drifts toward the majority type. So when a question
      names a customer, the tool description requires filtering on customer_id
      FIRST and letting search do only the semantic hop inside that customer's
      own interactions. That turns a 1,203-document problem into a handful of
      documents and makes the top-heaviness irrelevant.

   3. ROUGHLY 40% OF INTERACTIONS CARRY UNKNOWN SENTIMENT OR PRODUCT, which is a
      correct outcome of sql/05's confidence gate and not missing data. A hard
      attribute filter on sentiment_band or product_mentioned would silently
      exclude nearly half the corpus. The column descriptions say so in the
      payload the agent reads, and the orchestration instructions tell it to
      treat UNKNOWN as a value to reason about rather than a row to drop.

   max_results is 8 on interactions and 6 on product docs. Interactions get more
   because the useful signal is often the third or fourth hit once a customer
   filter is applied; clauses get fewer because a clause is self-contained and
   retrieving six of fourteen for a product is already most of the document.

   ----------------------------------------------------------------------------
   THE ORCHESTRATION RULE THAT MATTERS
   ----------------------------------------------------------------------------
   ALWAYS call next_best_actions for a named customer before recommending
   anything, and never invent a recommendation from the other three tools.

   This is not a preference about tidiness. The other three tools are each
   individually capable of supporting a confident, well-evidenced, entirely
   impermissible recommendation:

     interaction_search will happily surface a customer asking about a top-up
     loan. It cannot see that they are 45 days past due.

     product_terms will confirm that a 42-year-old in income band 4 meets the
     eligibility criteria for the product. The clause is real and the customer
     does meet it. It cannot see the DNC register, the open complaint or the
     vulnerability flag.

     portfolio_analytics can report that this customer sits in a cohort with a
     high propensity. Cohort membership is not permission.

   Only next_best_actions has read GOLD.NBA_ELIGIBLE, and only it returns the
   suppressed actions with the rule that blocked each one. Any other route to a
   recommendation is a route around the compliance layer.

   ----------------------------------------------------------------------------
   ACCESS, AND A TRAP THAT WILL WASTE AN HOUR
   ----------------------------------------------------------------------------
   Cortex Agents resolve privileges from the querying user's DEFAULT role, not
   the role active in their session. On this account SURAKASH's default role is
   ACCOUNTADMIN while every object here is owned by COCO_BUILDER, and
   COCO_BUILDER is granted only to the user -- not into the ACCOUNTADMIN
   hierarchy. So an agent that works perfectly under USE ROLE COCO_BUILDER fails
   under the API with a privilege error on the search services.

   §5 handles it, and the grant it needs cannot be made by COCO_BUILDER. That
   section is marked and is the one part of this file run on the coco_admin
   connection -- the same seam PROJECT_BRIEF D2 already documents for the
   Streamlit stage copy, made explicit rather than discovered.
   ============================================================================ */

USE ROLE COCO_BUILDER;
USE WAREHOUSE COCO_WH;
USE DATABASE C360_NBA;
USE SCHEMA APP;


/* ============================================================================
   PART 1 — THE SEARCH SERVICES MUST BE SERVING
   ----------------------------------------------------------------------------
   sql/10b suspends both to stop them metering on a trial account, and they were
   left suspended. A suspended service does not error when an agent queries it --
   it returns nothing, which the agent reports as "the customer never mentioned
   that". Resuming is therefore part of standing the agent up and not a separate
   operational chore.

   RESUME is idempotent, so this is safe on a re-run. sql/10c is the same
   operation with the refresh reasoning; it is repeated here so this file is
   runnable on its own.
   ============================================================================ */

ALTER CORTEX SEARCH SERVICE IF EXISTS APP.SEARCH_INTERACTIONS RESUME;
ALTER CORTEX SEARCH SERVICE IF EXISTS APP.SEARCH_PRODUCT_DOCS RESUME;

SHOW CORTEX SEARCH SERVICES IN SCHEMA APP;


/* ============================================================================
   PART 2 — THE AGENT
   ============================================================================ */

CREATE OR REPLACE AGENT APP.RM_COPILOT
  COMMENT = 'Relationship manager copilot for an Indian bank-and-insurer group. Four tools: Cortex Analyst over GOLD.SV_CUSTOMER_360 for portfolio questions, Cortex Search over interactions for what a customer said, Cortex Search over product clauses for whether an offer is permitted and on what terms, and APP.GET_NEXT_BEST_ACTIONS for the ranked actions for one named customer. Serves two personas: relationship managers asking about one customer, and portfolio managers asking about the book. Every recommendation for a named customer comes from the next-best-action engine, which is the only tool that can see the compliance suppressions; the agent is instructed never to assemble a recommendation from the other three. Amounts are reported in INR with Indian digit grouping and suppressed actions are always disclosed with their governing rule.'
  PROFILE = '{"display_name": "RM Copilot", "color": "blue"}'
  FROM SPECIFICATION
$$
models:
  orchestration: auto

orchestration:
  tool_not_accessible: reject
  budget:
    seconds: 90
    tokens: 32000

instructions:
  system: |
    You are the relationship manager copilot for an Indian bank-and-insurer
    group with 5,000 customers, covering both the insurance book (life, health,
    motor, home) and the lending book (home loans, personal loans, cards).

    You serve two kinds of user and they ask different questions.

    A RELATIONSHIP MANAGER asks about one customer they are about to speak to:
    what should I do, why, what did they say, am I allowed to offer this.

    A PORTFOLIO MANAGER asks about the book: how many, how much, which cohort,
    what is the trend, what is compliance costing us.

    Work out which you are being asked before choosing a tool. A named or
    numbered customer almost always means the first.

    Every figure in this system is measured against a stored as-of date, not
    against today. If you quote a day count, a renewal window or a "last
    contacted" figure, it is relative to that anchor. Say so when it matters.

  orchestration: |
    ROUTING

    Route "how many", "which customers", "what is the trend", "what is the
    total", "break down by", and anything about a cohort or the whole book to
    portfolio_analytics.

    Route "what did the customer say", "find calls about X", "did they ever
    mention Y", and anything about the content of a conversation to
    interaction_search.

    Route "why is this offer allowed", "what are the terms", "what is the
    eligibility", "what does the policy say", and anything needing the wording
    of a rule to product_terms.

    ALWAYS call next_best_actions for a named or numbered customer BEFORE
    recommending anything. This is not optional and there is no exception.
    NEVER invent, infer or assemble a recommendation from the other three tools.

    WHY THAT RULE EXISTS, because you will be tempted to break it. Each of the
    other three tools can support a confident and entirely impermissible
    recommendation. interaction_search can show a customer asking about a
    top-up loan and cannot see that they are 45 days past due. product_terms can
    confirm the customer meets a product's stated eligibility and cannot see the
    do-not-contact register, an open complaint or a vulnerability flag.
    portfolio_analytics can report that the customer's cohort converts well, and
    cohort membership is not permission. Only next_best_actions has read the
    eligibility ledger, and only it tells you what was blocked.

    If a user asks you to sell, offer, pitch or push a specific product to a
    named customer, that is still a recommendation. Call next_best_actions
    first, then answer from what it returned -- including telling them if the
    thing they asked for was suppressed and why.

    DO NOT call portfolio_analytics for a question about one named customer.
    next_best_actions already returns that customer's segment, value band,
    arrears state, care flags, contact permissions, holdings and gaps. Calling
    Analyst as well is slower, costs more, and risks quoting a portfolio
    aggregate as if it described the individual.

    USING interaction_search WELL

    When the question names a customer, ALWAYS filter on customer_id first and
    let the search do only the semantic hop within that customer's own
    interactions. The corpus is top-heavy -- one artefact type is 42% of it --
    so an unfiltered search drifts toward the majority type and returns the
    wrong customer's conversations.

    Judge relevance by RANK and by the gap between consecutive scores. If the
    top two or three results score close together and then there is a visible
    drop, the ones above the drop are the relevant set. DO NOT apply an absolute
    score threshold and do not describe a score as a confidence: the scores are
    not calibrated and the same number means different things for different
    queries.

    About 40% of interactions carry UNKNOWN sentiment or UNKNOWN product,
    because a confidence gate refused to guess rather than labelling them
    wrongly. UNKNOWN IS A REAL VALUE. Do not filter it out -- that would
    silently drop nearly half the corpus -- and do not read it as neutral or as
    an absence of feeling. If what you retrieve is largely UNKNOWN, say that the
    sentiment was not confidently classified rather than reporting no sentiment.

    ORDER OF WORK for a named customer: call next_best_actions first, then use
    interaction_search only to quote what the customer said in support of the
    action the engine chose, and product_terms only if the user asks whether it
    is permitted or on what terms.

  response: |
    AMOUNTS. Report every rupee figure in INR with Indian digit grouping:
    Rs 71,77,355 and not Rs 7,177,355. The next_best_actions tool returns
    pre-formatted strings in fields ending _fmt -- use those exactly as given
    rather than reformatting the numbers yourself. Use lakh and crore only if
    you also give the digits.

    CITE THE EVIDENCE BEHIND EVERY CLAIM. A recommendation cites the evidence
    entries the tool returned, by what they say and when: "on 19 Aug he told us
    his business had collapsed and he could not meet the EMI". A statement about
    permission cites the clause id from product_terms. A portfolio number says
    which metric it came from. Do not make a factual claim you cannot attribute
    to a tool result.

    SUPPRESSED ACTIONS ARE ALWAYS DISCLOSED. If next_best_actions returned
    anything in suppressed_actions, say so, name the action, and give the
    governing rule and what it observed. NEVER silently omit a suppressed
    action, and never present a suppression as though the product simply was not
    relevant -- the customer wanted it and a rule stopped us. If the user asked
    for exactly the thing that was suppressed, lead with that.

    When several rules blocked one action, say so. Reporting only the governing
    rule leaves the user thinking the sale becomes available once that one is
    fixed.

    NEVER SPECULATE about a customer's health, finances, family or personal
    circumstances beyond what the evidence states. If the evidence says a
    business closed, you may say the business closed. You may not infer what
    that means for the household, guess at a diagnosis behind a health claim,
    or theorise about why someone is behind on payments. If asked to, decline in
    one sentence and give what the evidence does support.

    Do not describe a propensity as a probability the customer will accept, and
    do not describe an expected value as revenue that will arrive. They are
    ranking quantities produced by a model.

    Never present a product gap as an eligibility verdict. A gap says a customer
    plausibly needs something; only the engine says whether it may be offered.

    STRUCTURE. Lead with the answer. For a single customer: the recommended
    action, why, the evidence, the disclosure to read out, then anything
    suppressed. Keep it tight enough to read before a call starts.

  sample_questions:
    # --- relationship manager, one customer at a time -----------------------
    - question: "What should I do next for customer 3925, and why?"
    - question: "I have a call with customer 2967 in ten minutes. What is the recommended action, and is there anything I must not offer?"
    - question: "What has customer 691 actually said to us recently?"
    - question: "Customer 923 wants a personal loan top-up. Are we allowed to offer it, and what are the terms?"
    # --- portfolio manager, the whole book ---------------------------------
    - question: "How many recommendations have we published, for how many customers, and what is the total expected value?"
    - question: "What is our suppression rate and which rules are blocking the most actions?"
    - question: "How many customers are in arrears, and how much exposure does that represent?"
    - question: "What is the split between sales actions and care actions in what we recommend?"

tools:
  - tool_spec:
      type: "cortex_analyst_text_to_sql"
      name: "portfolio_analytics"
      description: |
        Answers questions about the BOOK: counts, totals, rates, trends and
        cohort breakdowns across 5,000 customers, the insurance and lending
        books, claims, the outbound contact log, the published next-best-action
        recommendations, and the eligibility ledger that records what compliance
        blocked.

        USE IT FOR: how many customers / policies / loans / claims / contacts /
        recommendations; totals and averages in INR; lapse, arrears, conversion,
        opt-out, rejection and suppression rates; breakdowns by city, segment,
        product, channel, DPD bucket, action or suppression reason; how many
        customers with attribute X also have Y.

        DO NOT USE IT FOR: a question about one named customer -- use
        next_best_actions, which returns that customer's full profile and is
        cheaper and more accurate for an individual. Do not use it for anything
        needing the text of a conversation, or the wording of a product rule.

        Two things it will tell you that are easy to misread. Every day count is
        measured from a stored as-of date and not from today. The engine appears
        as two separate things: what was RECOMMENDED (3,917 published actions)
        and what was CONSIDERED (90,000 evaluated candidate actions) -- a
        suppressed action exists only in the second, so any suppression count or
        rate comes from there.
  - tool_spec:
      type: "cortex_search"
      name: "interaction_search"
      description: |
        Searches what customers ACTUALLY SAID: 1,203 interactions at
        conversation grain -- inbound and outbound calls with transcripts,
        emails, chats, branch notes and app messages -- each with a sentiment
        band, an intent, any product mentioned and flags for complaints,
        hardship, churn language, life events and competitor mentions.

        USE IT FOR: what did this customer say, find conversations about a
        topic, did they ever mention X, what was the tone, quote the customer in
        their own words.

        DO NOT USE IT FOR: deciding what to offer. It shows what a customer
        wants and cannot see whether we are permitted to provide it -- a
        customer asking for a top-up loan may be in arrears, and this tool
        cannot tell you. Recommendations come from next_best_actions only.

        HOW TO USE IT WELL, and these matter:

        WHEN THE QUESTION NAMES A CUSTOMER, FILTER ON customer_id FIRST. The
        corpus is top-heavy -- a single artefact type is 42% of it -- so an
        unfiltered semantic search drifts toward that type and toward other
        customers. Filter to the customer, then let the search find the
        semantically relevant conversation within their own history.

        JUDGE RELEVANCE BY RANK AND BY THE SCORE CLIFF, never by an absolute
        score. Look for the point where consecutive scores drop noticeably and
        treat what is above it as the relevant set. The scores are not
        calibrated across queries, so a given value means different things for
        different questions and a fixed threshold will sometimes return nothing
        for a customer who did discuss the topic.

        UNKNOWN IS A REAL VALUE, NOT MISSING DATA. About 40% of interactions
        carry sentiment_band = UNKNOWN or product_mentioned = UNKNOWN because a
        confidence gate declined to guess rather than label wrongly. Do not
        filter UNKNOWN out -- you would discard nearly half the corpus -- and do
        not read it as neutral. Report it as "not confidently classified".
  - tool_spec:
      type: "cortex_search"
      name: "product_terms"
      description: |
        Searches the product documents at CLAUSE grain: 224 self-contained
        clauses across 16 products, covering eligibility criteria, features,
        exclusions, fees and the IRDAI and RBI disclosures a real document
        carries. Every numeric threshold in a clause comes from the same product
        catalogue the eligibility rules are computed from, so a clause and the
        engine cannot disagree.

        USE IT FOR: what are the terms, what is the eligibility, why would this
        be allowed or not allowed under the product rules, what are the fees,
        what is excluded, what must be disclosed to the customer, what is the
        minimum age or income band.

        Cite clauses by chunk id, which is PRODUCT_CODE#CLAUSE_ID -- for example
        BNK_CARD_PLAT#ELIG-01. That is what makes an answer checkable.

        DO NOT USE IT FOR: deciding whether a specific customer may be offered
        something. A clause states the product's own criteria. It cannot see
        that this customer is on the do-not-contact register, has an open
        complaint, is flagged vulnerable, or is in arrears -- all of which
        override an otherwise satisfied eligibility rule. A customer can meet
        every clause in the document and still be correctly suppressed. Only
        next_best_actions knows.

        Judge relevance by rank and by the score cliff rather than by an
        absolute score, as with the interaction search.
  - tool_spec:
      type: "generic"
      name: "next_best_actions"
      description: |
        THE ONLY SOURCE OF RECOMMENDATIONS. Returns the ranked next best actions
        for ONE customer, and -- uniquely among the tools here -- the actions the
        engine wanted to take and a compliance rule blocked.

        CALL THIS BEFORE RECOMMENDING ANYTHING FOR A NAMED OR NUMBERED CUSTOMER,
        every time, including when the user has already named the product they
        want to sell. No other tool can see the compliance suppressions, so any
        recommendation not grounded in this tool's output is ungoverned.

        Returns, for one customer: their profile, value band and holdings; a
        care_posture block with arrears state, hardship signal, vulnerability
        flag, open complaint and KYC currency; a contact_permission block with
        the do-not-contact register and per-channel consent; up to three ranked
        actions each with the channel, the propensity, the expected value in INR
        both raw and pre-formatted, a written rationale, the resolved evidence
        behind it, the regulatory disclosure to read out, and the full
        rule-by-rule eligibility trace; and a suppressed_actions array of things
        the customer plausibly wants that a rule blocked, each with the value at
        stake, the governing suppression_reason and every rule that returned
        BLOCK with what it observed.

        INPUT: customer_id, the numeric id as it appears in the question. 1 to
        5000. Pass the digits only.

        CHECK status BEFORE READING ANYTHING ELSE. OK means actions were
        published. NO_ACTIONS means the customer exists but nothing was
        published -- read suppressed_actions to see whether that is because
        nothing was relevant or because everything relevant was blocked, and say
        which. UNKNOWN_CUSTOMER means no such customer: say so and recommend
        nothing. BAD_ARGUMENT means the id could not be read: ask for it.

        The two rupee totals in the summary are NOT comparable.
        total_expected_value_inr is propensity-weighted;
        suppressed_value_at_stake_inr is gross with no propensity applied. Never
        add or subtract them.
      input_schema:
        type: "object"
        properties:
          customer_id:
            type: "string"
            description: "The numeric customer id, 1 to 5000, digits only. For example 3925."
        required:
          - customer_id

tool_resources:
  portfolio_analytics:
    semantic_view: "C360_NBA.GOLD.SV_CUSTOMER_360"
    execution_environment:
      type: "warehouse"
      warehouse: "COCO_WH"
      query_timeout: 120

  interaction_search:
    search_service: "C360_NBA.APP.SEARCH_INTERACTIONS"
    id_column: "INTERACTION_ID"
    title_column: "SUBJECT"
    # 8 rather than 4: with a customer_id filter applied the candidate set is
    # small, and the useful signal is often the third or fourth hit. No filter is
    # set here -- filters belong on the call, per customer, and a static one
    # would apply to every question including the ones it is wrong for.
    max_results: 8
    columns_and_descriptions:
      BODY:
        description: "The full text of the interaction: a call transcript, an email, a chat log or a branch note."
        type: "string"
        searchable: true
        filterable: false
      SUBJECT:
        description: "Short subject line for the interaction."
        type: "string"
        searchable: true
        filterable: false
      SUMMARY_25W:
        description: "A 25-word summary of the interaction."
        type: "string"
        searchable: true
        filterable: false
      CUSTOMER_ID:
        description: "Numeric customer id, 1 to 5000. FILTER ON THIS FIRST whenever the question is about a named customer. The corpus is top-heavy, so an unfiltered search drifts toward the majority artefact type and toward other customers."
        type: "number"
        searchable: false
        filterable: true
      CHANNEL:
        description: "How the interaction happened. Values include CALL, EMAIL, CHAT, BRANCH, APP."
        type: "string"
        searchable: false
        filterable: true
      INTENT:
        description: "Classified intent of the interaction, from a 16-value taxonomy. May be UNKNOWN where the classifier was not confident, which is a real value and not missing data."
        type: "string"
        searchable: false
        filterable: true
      SENTIMENT_BAND:
        description: "Tone of the interaction: POSITIVE, NEUTRAL, NEGATIVE, MIXED or UNKNOWN. UNKNOWN covers roughly 40% of the corpus together with unknown product, because a confidence gate declined to guess. DO NOT FILTER UNKNOWN OUT and do not read it as neutral."
        type: "string"
        searchable: false
        filterable: true
      PRODUCT_MENTIONED:
        description: "Product family discussed, or UNKNOWN where none was confidently identified. UNKNOWN is a real value; filtering it out discards a large part of the corpus."
        type: "string"
        searchable: false
        filterable: true
      OCCURRED_AT:
        description: "When the interaction happened. Use for recency, remembering that recency is relative to the stored as-of date and not to today."
        type: "string"
        searchable: false
        filterable: true
      ARTEFACT_TYPE:
        description: "The kind of artefact: inbound or outbound call transcript, email, chat, branch note or app message. One type is 42% of the corpus, which is why a customer filter matters more than an artefact filter."
        type: "string"
        searchable: false
        filterable: true

  product_terms:
    search_service: "C360_NBA.APP.SEARCH_PRODUCT_DOCS"
    id_column: "CHUNK_ID"
    title_column: "CLAUSE_HEADING"
    # 6 of 14 clauses per product: a clause is self-contained, so six is already
    # most of a document and more would crowd the context without adding rules.
    max_results: 6
    columns_and_descriptions:
      CHUNK_TEXT:
        description: "The full text of one self-contained product clause, restating the product it belongs to and any threshold it depends on, so it still means something retrieved on its own."
        type: "string"
        searchable: true
        filterable: false
      CLAUSE_HEADING:
        description: "Heading of the clause."
        type: "string"
        searchable: true
        filterable: false
      CHUNK_ID:
        description: "The citation key, formed as PRODUCT_CODE#CLAUSE_ID -- for example BNK_CARD_PLAT#ELIG-01. Always cite this so the reader can check the clause."
        type: "string"
        searchable: false
        filterable: true
      PRODUCT_CODE:
        description: "Product code, for example BNK_CARD_PLAT or INS_MOTOR_COMP. Filter on this when the question is about a specific product."
        type: "string"
        searchable: false
        filterable: true
      PRODUCT_NAME:
        description: "Human-readable product name."
        type: "string"
        searchable: true
        filterable: true
      LINE_OF_BUSINESS:
        description: "INSURANCE or BANKING."
        type: "string"
        searchable: false
        filterable: true
      PRODUCT_FAMILY:
        description: "Product family, for example TERM, HEALTH, MOTOR, HOME, CARD, PERSONAL_LOAN, HOME_LOAN."
        type: "string"
        searchable: false
        filterable: true
      SECTION:
        description: "Which part of the document the clause is from: ELIGIBILITY, FEATURES, EXCLUSIONS, FEES or DISCLOSURES. Filter on ELIGIBILITY for criteria questions and on DISCLOSURES for what must be read to the customer."
        type: "string"
        searchable: false
        filterable: true
      VULNERABLE_ALLOWED:
        description: "Whether this product may be offered to a customer on the vulnerability register. Useful for showing the clause behind a vulnerability suppression, but it does NOT determine whether a given customer may be offered the product -- only next_best_actions does."
        type: "boolean"
        searchable: false
        filterable: true
      SELLABLE:
        description: "Whether the product is currently open to new business."
        type: "boolean"
        searchable: false
        filterable: true

  next_best_actions:
    type: "procedure"
    identifier: "C360_NBA.APP.GET_NEXT_BEST_ACTIONS"
    execution_environment:
      type: "warehouse"
      warehouse: "COCO_WH"
$$;


/* ============================================================================
   PART 3 — WHAT WAS BUILT
   ============================================================================ */

SHOW AGENTS IN SCHEMA APP;
DESCRIBE AGENT APP.RM_COPILOT;


/* ============================================================================
   PART 4 — GRANTS FOR COCO_BUILDER
   ----------------------------------------------------------------------------
   COCO_BUILDER owns everything here, so these are mostly no-ops that document
   what the agent needs rather than confer it. They are stated anyway, because
   the next role to use this agent will need exactly this list and inferring it
   from a failure message is slower than reading it.
   ============================================================================ */

GRANT USAGE ON AGENT APP.RM_COPILOT              TO ROLE COCO_BUILDER;
GRANT USAGE ON SCHEMA GOLD                       TO ROLE COCO_BUILDER;
GRANT USAGE ON SCHEMA APP                        TO ROLE COCO_BUILDER;
GRANT SELECT ON SEMANTIC VIEW GOLD.SV_CUSTOMER_360 TO ROLE COCO_BUILDER;
GRANT USAGE ON CORTEX SEARCH SERVICE APP.SEARCH_INTERACTIONS TO ROLE COCO_BUILDER;
GRANT USAGE ON CORTEX SEARCH SERVICE APP.SEARCH_PRODUCT_DOCS TO ROLE COCO_BUILDER;
GRANT USAGE ON PROCEDURE APP.GET_NEXT_BEST_ACTIONS(VARCHAR)  TO ROLE COCO_BUILDER;


/* ============================================================================
   PART 5 — THE ADMIN GRANT LIVES IN sql/18b
   ----------------------------------------------------------------------------
   One grant is needed that COCO_BUILDER cannot make, and it is in
   sql/18b_agent_grants_admin.sql rather than here so that THIS file stays
   cleanly re-runnable on the build connection. It was inline at first; a re-run
   then ended in "Grant not executed: Insufficient privileges", which is correct
   behaviour reported as a failure and exactly the kind of noise that trains
   somebody to stop reading the output.

   Same split, and the same reason, as sql/10b and sql/10c.

       snow sql --connection coco_admin -f sql/18b_agent_grants_admin.sql

   Run it once. See that file for why it is needed at all -- the short version is
   that Cortex Agents resolve privileges from the querying user's DEFAULT role.
   ============================================================================ */
