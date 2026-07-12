/* =====================================================================
   SQL ANALYTICS — Job Market Combined Dataset
   Engine: SQLite (works in any client that opens combined_jobs_data.db)
   Techniques used: CTEs, Window Functions, RANK/DENSE_RANK/ROW_NUMBER,
                     Recursive CTEs, Views
   ===================================================================== */

-------------------------------------------------------------------------
-- 1. WHICH SKILLS ARE GROWING FASTEST?
-- No table in the source data tracks individual skills over time, so
-- this uses the closest genuine time series available (clean_salaries,
-- 2020-2025, job_title x work_year) as a role-demand-growth proxy —
-- treat it as directional, not a literal skills answer.
-- A RECURSIVE CTE builds a gapless year "spine" so LAG() never skips a
-- year just because a role had zero postings that year.
-------------------------------------------------------------------------
DROP VIEW IF EXISTS vw_role_growth;
CREATE VIEW vw_role_growth AS
WITH RECURSIVE year_spine(yr) AS (
    SELECT MIN(work_year) FROM clean_salaries
    UNION ALL
    SELECT yr + 1 FROM year_spine WHERE yr + 1 <= (SELECT MAX(work_year) FROM clean_salaries)
),
role_years AS (
    SELECT DISTINCT job_title FROM clean_salaries
),
spine AS (
    SELECT r.job_title, y.yr AS work_year
    FROM role_years r CROSS JOIN year_spine y
),
yearly_counts AS (
    SELECT job_title, work_year, COUNT(*) AS postings, AVG(salary_in_usd) AS avg_salary
    FROM clean_salaries
    GROUP BY job_title, work_year
),
filled AS (
    SELECT s.job_title, s.work_year,
           COALESCE(yc.postings, 0)   AS postings,
           yc.avg_salary
    FROM spine s LEFT JOIN yearly_counts yc
      ON yc.job_title = s.job_title AND yc.work_year = s.work_year
),
with_growth AS (
    SELECT job_title, work_year, postings, avg_salary,
           LAG(postings) OVER (PARTITION BY job_title ORDER BY work_year) AS prev_postings,
           FIRST_VALUE(postings) OVER (PARTITION BY job_title ORDER BY work_year) AS first_year_postings,
           LAST_VALUE(postings) OVER (PARTITION BY job_title ORDER BY work_year
               ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS last_year_postings
    FROM filled
)
SELECT job_title,
       first_year_postings,
       last_year_postings,
       (last_year_postings - first_year_postings) AS net_growth,
       ROUND(
         CASE WHEN first_year_postings > 0
              THEN (last_year_postings * 1.0 / first_year_postings) - 1
              ELSE NULL END * 100, 1
       ) AS pct_growth_first_to_last_year,
       RANK() OVER (ORDER BY (last_year_postings - first_year_postings) DESC) AS growth_rank
FROM with_growth
GROUP BY job_title
-- first_year_postings (2020) was a tiny sample for most roles, so pct
-- growth explodes; net_growth (absolute postings added) is the more
-- reliable "fastest growing" signal and is what this view ranks by.
HAVING SUM(postings) >= 10          -- ignore near-empty roles (noise)
ORDER BY growth_rank;

-------------------------------------------------------------------------
-- 2. WHICH CITIES HAVE THE MOST JOBS?
-- RANK() + a running SUM() OVER() for cumulative share (Pareto view).
-------------------------------------------------------------------------
DROP VIEW IF EXISTS vw_city_job_counts;
CREATE VIEW vw_city_job_counts AS
WITH city_counts AS (
    SELECT city, state, COUNT(*) AS job_count
    FROM clean_jobs_cleaned_table
    WHERE city IS NOT NULL AND city != ''
    GROUP BY city, state
),
ranked AS (
    SELECT city, state, job_count,
           RANK() OVER (ORDER BY job_count DESC) AS city_rank,
           SUM(job_count) OVER (ORDER BY job_count DESC
               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_total,
           ROUND(100.0 * SUM(job_count) OVER (ORDER BY job_count DESC
               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
               / SUM(job_count) OVER (), 1) AS cumulative_pct
    FROM city_counts
)
SELECT * FROM ranked ORDER BY city_rank;

-------------------------------------------------------------------------
-- 3. WHICH COMPANIES HIRE THE MOST ANALYSTS?
-- DENSE_RANK() on companies whose postings fall in an "Analyst" title
-- category (from the standardized title_category column).
-------------------------------------------------------------------------
DROP VIEW IF EXISTS vw_top_analyst_companies;
CREATE VIEW vw_top_analyst_companies AS
WITH analyst_postings AS (
    SELECT company_clean, title_category
    FROM clean_data_analyst_raw
    WHERE title_category LIKE '%Analyst%'
      AND company_clean != 'Unknown'
),
company_counts AS (
    SELECT company_clean, COUNT(*) AS analyst_job_count
    FROM analyst_postings
    GROUP BY company_clean
)
SELECT company_clean, analyst_job_count,
       DENSE_RANK() OVER (ORDER BY analyst_job_count DESC) AS company_rank
FROM company_counts
ORDER BY company_rank;

-------------------------------------------------------------------------
-- 4. REMOTE VS HYBRID VS ONSITE
-------------------------------------------------------------------------
DROP VIEW IF EXISTS vw_work_mode_split;
CREATE VIEW vw_work_mode_split AS
WITH mode_counts AS (
    SELECT remote AS work_mode, COUNT(*) AS job_count
    FROM clean_jobs_cleaned_table
    WHERE remote IS NOT NULL
    GROUP BY remote
)
SELECT work_mode, job_count,
       ROUND(100.0 * job_count / SUM(job_count) OVER (), 1) AS pct_of_total,
       RANK() OVER (ORDER BY job_count DESC) AS mode_rank
FROM mode_counts
ORDER BY mode_rank;

-------------------------------------------------------------------------
-- 5. EXPERIENCE DISTRIBUTION
-------------------------------------------------------------------------
DROP VIEW IF EXISTS vw_experience_distribution;
CREATE VIEW vw_experience_distribution AS
WITH exp_counts AS (
    SELECT
        CASE experience_level
            WHEN 'EN' THEN 'Entry-level'
            WHEN 'MI' THEN 'Mid-level'
            WHEN 'SE' THEN 'Senior'
            WHEN 'EX' THEN 'Executive'
            ELSE experience_level
        END AS experience_level,
        COUNT(*) AS job_count,
        ROUND(AVG(salary_in_usd), 0) AS avg_salary
    FROM clean_salaries
    GROUP BY experience_level
)
SELECT experience_level, job_count, avg_salary,
       ROUND(100.0 * job_count / SUM(job_count) OVER (), 1) AS pct_of_total,
       RANK() OVER (ORDER BY job_count DESC) AS rank_by_volume
FROM exp_counts
ORDER BY rank_by_volume;

-------------------------------------------------------------------------
-- 6. SALARY BY SKILL
-- RECURSIVE CTE splits the comma-separated extracted_skills column
-- (SQLite has no native STRING_SPLIT / UNNEST) into one row per skill.
-------------------------------------------------------------------------
DROP VIEW IF EXISTS vw_salary_by_skill;
CREATE VIEW vw_salary_by_skill AS
WITH RECURSIVE split_skills(job_row, remaining, skill, avg_salary) AS (
    SELECT
        rowid,
        extracted_skills || ',' AS remaining,
        NULL,
        avg_salary
    FROM clean_cleaned_data_analyst_jobs
    WHERE extracted_skills IS NOT NULL AND extracted_skills != ''

    UNION ALL

    SELECT
        job_row,
        SUBSTR(remaining, INSTR(remaining, ',') + 1),
        TRIM(SUBSTR(remaining, 1, INSTR(remaining, ',') - 1)),
        avg_salary
    FROM split_skills
    WHERE remaining != ''
),
skill_rows AS (
    SELECT skill, avg_salary FROM split_skills WHERE skill IS NOT NULL AND skill != ''
),
agg AS (
    SELECT skill,
           COUNT(*) AS job_count,
           ROUND(AVG(avg_salary), 1) AS avg_salary_k,
           ROUND(MIN(avg_salary), 1) AS min_salary_k,
           ROUND(MAX(avg_salary), 1) AS max_salary_k
    FROM skill_rows
    GROUP BY skill
)
SELECT skill, job_count, avg_salary_k, min_salary_k, max_salary_k,
       RANK() OVER (ORDER BY avg_salary_k DESC) AS salary_rank
FROM agg
WHERE job_count >= 10        -- drop rare skills for reliability
ORDER BY salary_rank;

-------------------------------------------------------------------------
-- 7. SALARY BY LOCATION
-------------------------------------------------------------------------
DROP VIEW IF EXISTS vw_salary_by_location;
CREATE VIEW vw_salary_by_location AS
WITH loc_stats AS (
    SELECT company_location,
           COUNT(*) AS job_count,
           ROUND(AVG(salary_in_usd), 0) AS avg_salary,
           ROUND(MIN(salary_in_usd), 0) AS min_salary,
           ROUND(MAX(salary_in_usd), 0) AS max_salary
    FROM clean_salaries
    GROUP BY company_location
    HAVING COUNT(*) >= 5
)
SELECT company_location, job_count, avg_salary, min_salary, max_salary,
       RANK() OVER (ORDER BY avg_salary DESC) AS salary_rank,
       NTILE(4) OVER (ORDER BY avg_salary DESC) AS salary_quartile
FROM loc_stats
ORDER BY salary_rank;

-------------------------------------------------------------------------
-- 8. SALARY BY COMPANY SIZE
-------------------------------------------------------------------------
DROP VIEW IF EXISTS vw_salary_by_company_size;
CREATE VIEW vw_salary_by_company_size AS
WITH size_stats AS (
    SELECT
        CASE company_size WHEN 'S' THEN 'Small' WHEN 'M' THEN 'Medium' WHEN 'L' THEN 'Large' ELSE company_size END AS company_size,
        COUNT(*) AS job_count,
        ROUND(AVG(salary_in_usd), 0) AS avg_salary
    FROM clean_salaries
    GROUP BY company_size
)
SELECT company_size, job_count, avg_salary,
       RANK() OVER (ORDER BY avg_salary DESC) AS salary_rank
FROM size_stats
ORDER BY salary_rank;

-------------------------------------------------------------------------
-- 9. SKILL CO-OCCURRENCE
-- Self-join job_skills on job_id to build unordered skill pairs that
-- appear together on the same posting, ranked by frequency.
-- NOTE: job_skills/skills_lookup use a broad function/domain taxonomy
-- (Marketing, Sales, Finance, IT, Analyst, ...) from a different source
-- table than the technical tool skills (Python, SQL, Tableau, ...) used
-- in vw_salary_by_skill above — the two are not directly comparable.
-------------------------------------------------------------------------
DROP VIEW IF EXISTS vw_skill_cooccurrence;
CREATE VIEW vw_skill_cooccurrence AS
WITH pairs AS (
    SELECT a.job_id,
           a.skill_abr AS skill_a,
           b.skill_abr AS skill_b
    FROM job_skills a
    JOIN job_skills b
      ON a.job_id = b.job_id
     AND a.skill_abr < b.skill_abr        -- avoid duplicate/reversed pairs and self-pairs
),
pair_counts AS (
    SELECT skill_a, skill_b, COUNT(*) AS co_occurrences
    FROM pairs
    GROUP BY skill_a, skill_b
)
SELECT sa.skill_name AS skill_1, sb.skill_name AS skill_2, pc.co_occurrences,
       RANK() OVER (ORDER BY pc.co_occurrences DESC) AS pair_rank
FROM pair_counts pc
JOIN skills_lookup sa ON sa.skill_abr = pc.skill_a
JOIN skills_lookup sb ON sb.skill_abr = pc.skill_b
ORDER BY pair_rank;

/* =====================================================================
   Bonus: ranking within groups (ROW_NUMBER + PARTITION BY)
   Top-paying skill per experience-adjacent city, illustrating a
   partitioned ranking rather than a single global one.
   ===================================================================== */
DROP VIEW IF EXISTS vw_top_skill_per_role;
CREATE VIEW vw_top_skill_per_role AS
WITH RECURSIVE split_skills(job_row, remaining, skill, title_category, avg_salary) AS (
    SELECT rowid, extracted_skills || ',', NULL, title_category, avg_salary
    FROM clean_cleaned_data_analyst_jobs
    WHERE extracted_skills IS NOT NULL AND extracted_skills != ''
    UNION ALL
    SELECT job_row,
           SUBSTR(remaining, INSTR(remaining, ',') + 1),
           TRIM(SUBSTR(remaining, 1, INSTR(remaining, ',') - 1)),
           title_category, avg_salary
    FROM split_skills
    WHERE remaining != ''
),
skill_rows AS (
    SELECT skill, title_category, avg_salary
    FROM split_skills WHERE skill IS NOT NULL AND skill != ''
),
agg AS (
    SELECT title_category, skill, COUNT(*) AS job_count, ROUND(AVG(avg_salary),1) AS avg_salary_k
    FROM skill_rows
    GROUP BY title_category, skill
),
ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY title_category ORDER BY job_count DESC) AS rn
    FROM agg
)
SELECT title_category, skill, job_count, avg_salary_k
FROM ranked
WHERE rn = 1
ORDER BY job_count DESC;
