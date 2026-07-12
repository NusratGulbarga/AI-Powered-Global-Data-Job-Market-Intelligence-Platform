# Power BI Dashboard — Build Guide

## Setup
1. Open Power BI Desktop → **Get Data → Excel Workbook** → select `PowerBI_Data_Model.xlsx` → check all sheets → **Load**.
2. Go to **Model view** and add these relationships (drag field to field):
   - `fact_analyst_jobs[extracted_skills]` doesn't relate directly (it's a comma list) — for skill-level
     visuals use `dim_skill_salary` and `dim_skill_cooccurrence`, which are already pre-aggregated per skill.
   - `fact_salaries[work_year]` → use directly on axes; no separate date table needed (whole-year granularity).
   - Other tables are mostly pre-aggregated (`dim_*`) and used standalone per page — a full star schema isn't
     necessary here since the source datasets don't share a common job-ID key (documented in the SQL analytics
     pass). Treat each `dim_/fact_` table as feeding its own page rather than forcing one universal model.
3. Create a `_Measures` table (Model view → New Table → `_Measures = {BLANK()}`) and paste in everything from
   `DAX_Measures.txt`.
4. Suggested theme: View → Themes → pick a neutral corporate theme; keep one accent color per page for KPI cards.

---

## Page 1 — Executive Dashboard
**Purpose:** one-glance health check across the whole dataset.
- KPI cards (top row): `[Total Postings]`, `[Avg Salary (USD)]`, `[Total Companies]`, `% Remote-Friendly (AI dataset)`
- Line chart: Avg Salary (USD) by `work_year` (fact_salaries)
- Donut chart: `dim_work_mode_split` — work_mode vs job_count
- Bar chart: `dim_experience_distribution` — experience_level vs job_count
- Slicers (top of page, apply to all): work_year, experience_level, company_size

## Page 2 — Hiring Trends
- Line/area chart: postings by `work_year` from `fact_salaries` (use `[Total Postings]`)
- Stacked area: experience-level mix by year (`fact_salaries`, work_year on axis, experience_level as legend, count as value)
- Line chart: `dim_remote_trends` — remote_ratio trend by role/year
- Table: `dim_role_growth` sorted by `growth_rank`, conditional formatting (data bars) on `net_growth`

## Page 3 — Salary Analytics
- KPI cards: `[Avg Salary (USD)]`, `[Median Salary (USD)]`, `[Salary P25]`, `[Salary P75]`
- Box-and-whisker (or clustered column of P25/median/P75) by `experience_level`
- Scatter chart: `Rating` vs `avg_salary_k` (fact_analyst_jobs) — turn on trend line via Analytics pane
- Bar chart: `dim_salary_trends` — avg salary by role over time

## Page 4 — Skill Demand
- Bar chart: `dim_skill_salary` — skill vs job_count, colored by avg_salary_k
- Matrix/table: `dim_skill_cooccurrence` top pairs (skill_1, skill_2, co_occurrences), sorted by pair_rank
- Word-cloud style visual (needs the free "Word Cloud" custom visual from AppSource) fed by `dim_skill_salary[skill]` sized by job_count
- Slicer: title_category (fact_analyst_jobs) to filter skill demand by role type

## Page 5 — Regional Analysis
- Filled map or bubble map: `dim_city_jobs` (city/state) sized by job_count — Power BI will geocode city/state automatically
- Bar chart: `dim_location_salary` — company_location vs avg_salary, ranked
- Table: `dim_country_salary` as a cross-check reference panel
- Slicer: salary_quartile (from `dim_location_salary`) to isolate top-paying regions

## Page 6 — Company Analysis
- Bar chart: `dim_top_analyst_companies` — company_clean vs analyst_job_count (top N via visual filter, e.g. top 20)
- Column chart: `dim_company_size_salary` — company_size vs avg_salary
- Table: `fact_analyst_jobs` grouped by company — count of postings, avg rating, avg salary (build as a Power BI matrix visual: Rows = company, Values = count, AVERAGE(Rating), AVERAGE(avg_salary_k))

## Page 7 — AI Skill Demand
- KPI cards: `[Avg AI Workload Ratio]`, `[High Automation Risk Jobs]`, `% Remote-Friendly (AI dataset)`
- Bar chart: `ai_job_market_insights` — Required_Skills vs count of postings, colored by AI_Adoption_Level
- Scatter: `ai_impact_on_jobs` — AI_Workload_Ratio vs Tasks, colored by Domain
- Stacked bar: `ai_job_market_insights` — Job_Growth_Projection (Growth/Stable/Decline) by Industry

## Page 8 — Forecast Dashboard
- Line chart: Avg Salary (USD) by `work_year` (fact_salaries) → right-click the visual's Analytics pane →
  **Forecast** → set forecast length to 2 years. This uses Power BI's native exponential-smoothing forecast,
  which is more appropriate here than a manual DAX trend given only 6 years of history.
- Repeat the same forecast visual filtered per `experience_level` (small multiples, one tile per level)
- Card: `[YoY Posting Growth %]`, `[Avg Salary YoY Growth %]`
- Caveat callout (text box): "Forecast based on only 6 years of history (2020–2025); treat as directional."

---

## Notes on data limitations (carried over from the SQL/Python analytics passes)
- No table tracks individual **skills** over time — `dim_role_growth` is a role-level proxy, not a literal skill-growth metric.
- `dim_skill_cooccurrence` uses a different, broader skill taxonomy (job function areas: Marketing, Sales, Finance…)
  than `dim_skill_salary` (specific tools: Python, SQL, Tableau…) — don't merge them in one visual without a label
  clarifying the source.
- `fact_jobs_indeed`, `fact_analyst_jobs`, and `fact_salaries` come from three different original surveys/scrapes
  with no shared job ID — cross-filtering between them will silently produce no results. Keep each on its own
  page/visuals as scoped above rather than slicing fact_salaries by a field from fact_analyst_jobs.
