/*
===============================================================================
FINAL COMPANY / INDUSTRY PIPELINE
===============================================================================

Purpose
-------
Reproduces the final SQL-side methodology used for:
  1. company-industry enrichment scope selection;
  2. canonical/reduced company mapping;
  3. propagation of existing industry classifications to aliases;
  4. creation of Power BI-ready company and job-posting objects;
  5. strict industry-matched company table;
  6. QA and final coverage calculations.

Important
---------
The actual industry research/classification was performed outside SQL
(registries, AI/Luna, web research and review) and stored in
public.company_industry. This script uses those completed classifications.

Final validated results at time of creation:
  Raw postings:                        1,907,499
  Raw company_dim records:               247,337
  Canonical companies:                   199,391
  Strict industry-matched companies:         992
  Strict matched-company coverage:          0.50%
  Strict matched postings:                448,176
  Strict matched-posting coverage:          23.50%

===============================================================================
*/


-- ============================================================================
-- A. CURRENT INDUSTRY ENRICHMENT SCOPE
-- ============================================================================
-- Logic:
--   * Start from job_postings_fact.
--   * Remove known non-employers, staffing/recruitment and job aggregators.
--   * Canonicalize known aliases.
--   * Determine market size AFTER those employer exclusions.
--   * Apply company posting thresholds:
--       cleaned country <    500 -> minimum 1 posting
--       500 - 1,000          -> minimum 10
--       1,001 - 5,000        -> minimum 25
--       5,001 - 10,000       -> minimum 50
--       10,001 - 35,000      -> minimum 100
--       > 35,000             -> minimum 150
--   * Markets >=500 postings: retain at least top 5 plus enough eligible
--     employers to cross 70% of threshold-eligible postings.
--   * Markets <500 postings: retain top 3 employers.

CREATE OR REPLACE VIEW public.industry_enrichment_scope AS

WITH source_company_country AS (
    SELECT
        j.job_country,
        j.company_id,
        c.name AS company_name,
        COALESCE(
            alias.canonical_company_name,
            NULLIF(industry.canonical_company_name, ''),
            c.name
        ) AS canonical_company_name,
        COUNT(DISTINCT j.job_id) AS source_posting_count

    FROM public.job_postings_fact AS j

    INNER JOIN public.company_dim AS c
        ON c.company_id = j.company_id

    LEFT JOIN public.company_industry AS industry
        ON industry.company_id = j.company_id

    LEFT JOIN public.company_canonical_alias AS alias
        ON alias.alias_normalized = LOWER(
            REGEXP_REPLACE(TRIM(c.name), '\s+', ' ', 'g')
        )

    LEFT JOIN public.company_scope_exclusion AS exclusion
        ON exclusion.company_name_normalized = LOWER(
            REGEXP_REPLACE(TRIM(c.name), '\s+', ' ', 'g')
        )

    WHERE j.job_country IS NOT NULL
      AND TRIM(j.job_country) <> ''
      AND j.company_id IS NOT NULL
      AND exclusion.company_name_normalized IS NULL
      AND COALESCE(industry.industry_group, '') <> 'Staffing & Recruitment'
      AND COALESCE(industry.match_status, '') NOT LIKE 'Excluded%'
      AND LOWER(c.name) !~
          '(^|[^a-z])(recruitment|recruiting|recruiter|recruiters|staffing|headhunting|headhunter)([^a-z]|$)'
      AND LOWER(c.name) NOT LIKE '%executive search%'
      AND LOWER(c.name) NOT LIKE '%employment agency%'
      AND LOWER(TRIM(c.name)) NOT LIKE 'bebee%'
      AND LOWER(TRIM(c.name)) NOT LIKE 'jobs via %'
      AND LOWER(TRIM(c.name)) NOT LIKE 'jobleads%'
      AND LOWER(TRIM(c.name)) NOT LIKE 'mygwork%'
      AND LOWER(TRIM(c.name)) NOT LIKE 'whatjobs%'
      AND LOWER(TRIM(c.name)) NOT LIKE 'tideri%'

    GROUP BY
        j.job_country,
        j.company_id,
        c.name,
        COALESCE(
            alias.canonical_company_name,
            NULLIF(industry.canonical_company_name, ''),
            c.name
        )
),

canonical_company_country AS (
    SELECT
        job_country,
        (ARRAY_AGG(
            canonical_company_name
            ORDER BY source_posting_count DESC
        ))[1] AS canonical_company_name,
        SUM(source_posting_count)::BIGINT AS posting_count,
        (ARRAY_AGG(
            company_id
            ORDER BY source_posting_count DESC, company_id
        ))[1] AS company_id,
        (ARRAY_AGG(
            company_name
            ORDER BY source_posting_count DESC, company_id
        ))[1] AS company_name

    FROM source_company_country

    GROUP BY
        job_country,
        LOWER(
            REGEXP_REPLACE(
                TRIM(canonical_company_name),
                '\s+',
                ' ',
                'g'
            )
        )
),

country_stats AS (
    SELECT
        job_country,
        SUM(posting_count)::BIGINT AS cleaned_country_postings,
        COUNT(*) AS canonical_company_count
    FROM canonical_company_country
    GROUP BY job_country
),

thresholded_companies AS (
    SELECT
        company.job_country,
        company.canonical_company_name,
        company.posting_count,
        company.company_id,
        company.company_name,
        country.cleaned_country_postings,
        country.canonical_company_count,
        CASE
            WHEN country.cleaned_country_postings < 500 THEN 1
            WHEN country.cleaned_country_postings <= 1000 THEN 10
            WHEN country.cleaned_country_postings <= 5000 THEN 25
            WHEN country.cleaned_country_postings <= 10000 THEN 50
            WHEN country.cleaned_country_postings <= 35000 THEN 100
            ELSE 150
        END AS minimum_company_postings

    FROM canonical_company_country AS company
    INNER JOIN country_stats AS country
        ON country.job_country = company.job_country
),

company_flags AS (
    SELECT
        thresholded.*,
        posting_count >= minimum_company_postings AS threshold_eligible
    FROM thresholded_companies AS thresholded
),

ranked_companies AS (
    SELECT
        flags.*,
        ROW_NUMBER() OVER (
            PARTITION BY job_country
            ORDER BY posting_count DESC, canonical_company_name, company_id
        ) AS company_rank,

        SUM(
            CASE WHEN threshold_eligible THEN posting_count ELSE 0 END
        ) OVER (
            PARTITION BY job_country
            ORDER BY posting_count DESC, canonical_company_name, company_id
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS cumulative_eligible_postings,

        SUM(
            CASE WHEN threshold_eligible THEN posting_count ELSE 0 END
        ) OVER (
            PARTITION BY job_country
        ) AS total_eligible_postings

    FROM company_flags AS flags
),

selected_companies AS (
    SELECT
        ranked.*,
        CASE
            WHEN cleaned_country_postings >= 500 THEN 0.70
            ELSE NULL::NUMERIC
        END AS coverage_target

    FROM ranked_companies AS ranked

    WHERE CASE
        WHEN cleaned_country_postings < 500
            THEN company_rank <= 3
        ELSE
            company_rank <= 5
            OR (
                threshold_eligible
                AND cumulative_eligible_postings - posting_count
                    < total_eligible_postings * 0.70
            )
    END
),

selected_with_totals AS (
    SELECT
        selected.*,
        SUM(posting_count) OVER (
            PARTITION BY job_country
        ) AS selected_country_postings,
        SUM(posting_count) OVER (
            PARTITION BY job_country
            ORDER BY posting_count DESC, canonical_company_name, company_id
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS selected_cumulative_postings
    FROM selected_companies AS selected
)

SELECT
    job_country,
    company_id,
    company_name,
    canonical_company_name,
    posting_count,
    company_rank,
    cumulative_eligible_postings AS cumulative_postings,
    total_eligible_postings,
    cleaned_country_postings AS total_market_postings,
    coverage_target,
    CASE
        WHEN total_eligible_postings > 0
        THEN ROUND(
            100.0 * cumulative_eligible_postings / total_eligible_postings,
            2
        )
        ELSE NULL::NUMERIC
    END AS cumulative_eligible_percentage,
    selected_country_postings,
    (
        selected_cumulative_postings - posting_count
        < selected_country_postings * 0.90
    ) AS web_review_eligible

FROM selected_with_totals;


-- ============================================================================
-- B. SCOPE-FUNNEL VALIDATION
-- ============================================================================

WITH country_totals AS (
    SELECT
        job_country,
        MAX(total_market_postings) AS cleaned_postings,
        MAX(total_eligible_postings) AS threshold_eligible_postings
    FROM public.industry_enrichment_scope
    GROUP BY job_country
),
scope_totals AS (
    SELECT SUM(posting_count) AS selected_postings
    FROM public.industry_enrichment_scope
),
raw_totals AS (
    SELECT COUNT(DISTINCT job_id) AS raw_postings
    FROM public.job_postings_fact
)
SELECT
    '1 - Raw postings' AS stage,
    raw_postings AS postings,
    100.00 AS pct_of_raw
FROM raw_totals

UNION ALL

SELECT
    '2 - After employer/job-board exclusions',
    SUM(cleaned_postings),
    ROUND(100.0 * SUM(cleaned_postings) / MAX(raw_postings), 2)
FROM country_totals
CROSS JOIN raw_totals

UNION ALL

SELECT
    '3 - After country-specific company thresholds',
    SUM(threshold_eligible_postings),
    ROUND(100.0 * SUM(threshold_eligible_postings) / MAX(raw_postings), 2)
FROM country_totals
CROSS JOIN raw_totals

UNION ALL

SELECT
    '4 - After 70% / top-3 selection',
    selected_postings,
    ROUND(100.0 * selected_postings / raw_postings, 2)
FROM scope_totals
CROSS JOIN raw_totals;


-- ============================================================================
-- C. BUILD FINAL UNICODE-SAFE CANONICAL COMPANY MAPPING
-- ============================================================================
-- This is the corrected version. The earlier [a-z0-9]-only version was NOT
-- safe for non-Latin company names, so this implementation preserves Unicode.

BEGIN;

DROP VIEW IF EXISTS public.job_postings_reduced_v;
DROP TABLE IF EXISTS public.company_reduced_industry_matched;
DROP TABLE IF EXISTS public.company_reduced_dim;
DROP TABLE IF EXISTS public.company_reduced_map;

CREATE TABLE public.company_reduced_map AS

WITH geo_suffixes AS (
    SELECT DISTINCT
        TRIM(
            REGEXP_REPLACE(
                LOWER(job_country),
                '[^a-z0-9]+',
                ' ',
                'g'
            )
        ) AS suffix
    FROM public.job_postings_fact
    WHERE job_country IS NOT NULL
      AND TRIM(job_country) <> ''

    UNION SELECT 'uk'
    UNION SELECT 'u k'
    UNION SELECT 'usa'
    UNION SELECT 'u s a'
    UNION SELECT 'us'
    UNION SELECT 'u s'
    UNION SELECT 'uae'
    UNION SELECT 'u a e'
    UNION SELECT 'ksa'
),

geo_regex AS (
    SELECT
        ' (' ||
        STRING_AGG(suffix, '|' ORDER BY LENGTH(suffix) DESC)
        || ')$' AS pattern
    FROM geo_suffixes
    WHERE suffix <> ''
),

base AS (
    SELECT
        c.company_id,
        c.name AS original_company_name,
        COALESCE(
            a.canonical_company_name,
            NULLIF(ci.canonical_company_name, ''),
            c.name
        ) AS preferred_company_name,
        CASE
            WHEN a.canonical_company_name IS NOT NULL THEN 1
            WHEN NULLIF(ci.canonical_company_name, '') IS NOT NULL THEN 2
            ELSE 3
        END AS source_priority

    FROM public.company_dim AS c

    LEFT JOIN public.company_industry AS ci
        ON ci.company_id = c.company_id

    LEFT JOIN public.company_canonical_alias AS a
        ON a.alias_normalized = LOWER(
            REGEXP_REPLACE(TRIM(c.name), '\s+', ' ', 'g')
        )
),

normalized AS (
    SELECT
        *,
        CASE
            -- Pure ASCII names: normalize punctuation as well as whitespace.
            WHEN OCTET_LENGTH(preferred_company_name)
                 = CHAR_LENGTH(preferred_company_name)
            THEN TRIM(
                REGEXP_REPLACE(
                    LOWER(preferred_company_name),
                    '[^a-z0-9]+',
                    ' ',
                    'g'
                )
            )

            -- Unicode names: preserve their characters and only normalize
            -- whitespace. This prevents unrelated non-Latin names collapsing
            -- to an empty key.
            ELSE LOWER(
                REGEXP_REPLACE(
                    TRIM(preferred_company_name),
                    '\s+',
                    ' ',
                    'g'
                )
            )
        END AS normalized_name,

        OCTET_LENGTH(preferred_company_name)
            = CHAR_LENGTH(preferred_company_name) AS is_ascii

    FROM base
),

legal_clean AS (
    SELECT
        *,
        CASE
            WHEN is_ascii
            THEN TRIM(
                REGEXP_REPLACE(
                    normalized_name,
                    '(\s+(pte ltd|pty ltd|co ltd|incorporated|inc|llc|ltd|limited|plc|corp|corporation|gmbh|sarl|srl|spa|ag|se|bv|nv|oy|ab|aps))+$',
                    '',
                    'g'
                )
            )
            ELSE normalized_name
        END AS legal_clean_name
    FROM normalized
),

available_names AS (
    SELECT DISTINCT legal_clean_name
    FROM legal_clean
    WHERE legal_clean_name <> ''
),

geo_candidates AS (
    SELECT
        lc.*,
        TRIM(
            REGEXP_REPLACE(
                lc.legal_clean_name,
                gr.pattern,
                '',
                'g'
            )
        ) AS possible_root
    FROM legal_clean AS lc
    CROSS JOIN geo_regex AS gr
),

geo_clean AS (
    SELECT
        gc.*,
        CASE
            -- Strip a country suffix only if the base company independently
            -- exists. This avoids blindly turning names such as Air Canada
            -- into a generic root.
            WHEN b.legal_clean_name IS NOT NULL
             AND gc.possible_root <> ''
            THEN gc.possible_root
            ELSE gc.legal_clean_name
        END AS final_normalized_name

    FROM geo_candidates AS gc

    LEFT JOIN available_names AS b
        ON b.legal_clean_name = gc.possible_root
),

company_keys AS (
    SELECT
        *,
        CASE
            WHEN final_normalized_name IS NULL
              OR TRIM(final_normalized_name) = ''
            THEN 'id:' || company_id::TEXT

            WHEN OCTET_LENGTH(final_normalized_name)
                 = CHAR_LENGTH(final_normalized_name)
            THEN REGEXP_REPLACE(final_normalized_name, '\s+', '', 'g')

            ELSE 'unicode:' || LOWER(
                REGEXP_REPLACE(
                    TRIM(final_normalized_name),
                    '\s+',
                    ' ',
                    'g'
                )
            )
        END AS reduced_company_key
    FROM geo_clean
),

mapped AS (
    SELECT
        *,
        MIN(company_id) OVER (
            PARTITION BY reduced_company_key
        ) AS reduced_company_id,

        FIRST_VALUE(preferred_company_name) OVER (
            PARTITION BY reduced_company_key
            ORDER BY source_priority, company_id
        ) AS reduced_company_name
    FROM company_keys
)

SELECT
    company_id AS original_company_id,
    original_company_name,
    reduced_company_id,
    reduced_company_name,
    reduced_company_key
FROM mapped;

CREATE UNIQUE INDEX idx_reduced_map_original
    ON public.company_reduced_map(original_company_id);

CREATE INDEX idx_reduced_map_reduced
    ON public.company_reduced_map(reduced_company_id);


-- ============================================================================
-- D. PROPAGATE INDUSTRIES TO CANONICAL COMPANIES
-- ============================================================================

CREATE TABLE public.company_reduced_dim AS

WITH industry_votes AS (
    SELECT
        m.reduced_company_id,
        ci.industry_group,
        COUNT(*) AS votes

    FROM public.company_reduced_map AS m

    INNER JOIN public.company_industry AS ci
        ON ci.company_id = m.original_company_id

    WHERE ci.industry_group IS NOT NULL
      AND ci.industry_group <> 'Unknown'

    GROUP BY
        m.reduced_company_id,
        ci.industry_group
),

industry_ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY reduced_company_id
            ORDER BY votes DESC, industry_group
        ) AS rn,
        COUNT(*) OVER (
            PARTITION BY reduced_company_id
        ) AS industry_count
    FROM industry_votes
),

company_groups AS (
    SELECT
        reduced_company_id,
        MIN(reduced_company_name) AS company_name,
        MIN(reduced_company_key) AS reduced_company_key,
        COUNT(*) AS merged_company_ids
    FROM public.company_reduced_map
    GROUP BY reduced_company_id
)

SELECT
    cg.reduced_company_id AS company_id,
    cg.company_name,
    cg.reduced_company_key,
    cg.merged_company_ids,
    ir.industry_group,
    COALESCE(ir.industry_count, 0) AS industry_count,
    COALESCE(ir.industry_count, 0) > 1 AS industry_conflict

FROM company_groups AS cg

LEFT JOIN industry_ranked AS ir
    ON ir.reduced_company_id = cg.reduced_company_id
   AND ir.rn = 1;

ALTER TABLE public.company_reduced_dim
ADD PRIMARY KEY (company_id);


-- Intentional resolutions of the two genuine classification disagreements
-- discovered during canonicalization QA.
UPDATE public.company_reduced_dim
SET
    industry_group = 'Media & Entertainment',
    industry_conflict = FALSE,
    industry_count = 1
WHERE reduced_company_key = 'tiktok';

UPDATE public.company_reduced_dim
SET
    industry_group = 'Transportation & Logistics',
    industry_conflict = FALSE,
    industry_count = 1
WHERE reduced_company_key = 'wolt';


-- ============================================================================
-- E. POWER BI-READY REDUCED JOB POSTINGS
-- ============================================================================

CREATE OR REPLACE VIEW public.job_postings_reduced_v AS
SELECT
    j.*,
    m.reduced_company_id,
    m.reduced_company_name
FROM public.job_postings_fact AS j
LEFT JOIN public.company_reduced_map AS m
    ON m.original_company_id = j.company_id;


-- ============================================================================
-- F. STRICT INDUSTRY-MATCHED COMPANY TABLE
-- ============================================================================
-- Exactly three columns are retained for the Power BI industry dimension.

CREATE TABLE public.company_reduced_industry_matched AS
SELECT
    company_id,
    company_name,
    industry_group AS company_industry
FROM public.company_reduced_dim
WHERE industry_group IS NOT NULL
  AND industry_group NOT IN (
      'Unknown',
      'Job-search portal',
      'Placeholder / Unverified'
  )
ORDER BY company_id;

COMMIT;


-- ============================================================================
-- G. CANONICALIZATION QA
-- ============================================================================

-- Empty keys must equal zero.
SELECT COUNT(*) AS empty_company_keys
FROM public.company_reduced_map
WHERE COALESCE(TRIM(reduced_company_key), '') = '';

-- Remaining industry conflicts must equal zero after intentional overrides.
SELECT COUNT(*) AS remaining_industry_conflicts
FROM public.company_reduced_dim
WHERE industry_conflict = TRUE;

-- Inspect the largest merges for obvious false-positive entity resolution.
SELECT
    reduced_company_id,
    reduced_company_name,
    COUNT(*) AS original_company_ids
FROM public.company_reduced_map
GROUP BY reduced_company_id, reduced_company_name
ORDER BY original_company_ids DESC
LIMIT 20;


-- ============================================================================
-- H. COMPANY-DIMENSION REDUCTION
-- ============================================================================

SELECT
    (SELECT COUNT(*) FROM public.company_dim) AS original_companies,
    (SELECT COUNT(*) FROM public.company_reduced_dim) AS reduced_companies,
    (SELECT COUNT(*) FROM public.company_dim)
      - (SELECT COUNT(*) FROM public.company_reduced_dim) AS companies_merged,
    ROUND(
        100.0 * (
            (SELECT COUNT(*) FROM public.company_dim)
            - (SELECT COUNT(*) FROM public.company_reduced_dim)
        ) / NULLIF((SELECT COUNT(*) FROM public.company_dim), 0),
        2
    ) AS reduction_pct;


-- ============================================================================
-- I. STRICT FINAL INDUSTRY COVERAGE
-- ============================================================================

WITH company_stats AS (
    SELECT
        (SELECT COUNT(*) FROM public.company_reduced_dim) AS total_companies,
        (SELECT COUNT(*) FROM public.company_reduced_industry_matched)
            AS industry_matched_companies
),
posting_stats AS (
    SELECT
        COUNT(DISTINCT j.job_id) AS total_postings,
        COUNT(DISTINCT j.job_id) FILTER (
            WHERE c.company_id IS NOT NULL
        ) AS industry_matched_postings
    FROM public.job_postings_reduced_v AS j
    LEFT JOIN public.company_reduced_industry_matched AS c
        ON c.company_id = j.reduced_company_id
)
SELECT
    c.total_companies,
    c.industry_matched_companies,
    ROUND(
        100.0 * c.industry_matched_companies
        / NULLIF(c.total_companies, 0),
        2
    ) AS company_coverage_pct,
    p.total_postings,
    p.industry_matched_postings,
    ROUND(
        100.0 * p.industry_matched_postings
        / NULLIF(p.total_postings, 0),
        2
    ) AS posting_coverage_pct
FROM company_stats AS c
CROSS JOIN posting_stats AS p;


-- ============================================================================
-- J. OPTIONAL DIAGNOSTIC: INDUSTRY-MATCHED POSTING COVERAGE ONLY
-- ============================================================================

SELECT
    COUNT(DISTINCT j.job_id) AS industry_matched_postings,
    (SELECT COUNT(DISTINCT job_id) FROM public.job_postings_fact)
        AS total_postings,
    ROUND(
        100.0 * COUNT(DISTINCT j.job_id)
        / NULLIF(
            (SELECT COUNT(DISTINCT job_id) FROM public.job_postings_fact),
            0
        ),
        2
    ) AS industry_matched_posting_pct
FROM public.job_postings_reduced_v AS j
INNER JOIN public.company_reduced_industry_matched AS c
    ON c.company_id = j.reduced_company_id;


/*
===============================================================================
PSQL CLIENT EXPORT COMMANDS (run in psql, NOT pgAdmin SQL Query Tool)
===============================================================================

\copy public.company_reduced_dim TO 'C:/Users/reneg/Downloads/company_reduced_dim.csv' WITH (FORMAT CSV, HEADER TRUE, ENCODING 'UTF8')

\copy (SELECT * FROM public.job_postings_reduced_v) TO 'C:/Users/reneg/Downloads/job_postings_reduced.csv' WITH (FORMAT CSV, HEADER TRUE, ENCODING 'UTF8')

\copy public.company_reduced_industry_matched TO 'C:/Users/reneg/Downloads/company_reduced_industry_matched.csv' WITH (FORMAT CSV, HEADER TRUE, ENCODING 'UTF8')

===============================================================================
*/
