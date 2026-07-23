-- =============================================================================
-- 3.2 电子围栏打标记.sql
--
-- 函数清单：
--   gis_mark_electric_fence                 标记网格电子围栏障碍
--   gis_refresh_electric_fence              刷新网格电子围栏标记
--   gis_refresh_electric_fence_add          新增电子围栏后局部刷新
--   gis_refresh_electric_fence_delete       删除电子围栏后局部刷新
--   gis_refresh_electric_fence_edit         编辑电子围栏后局部刷新
--
-- =============================================================================

-- ============================================================ gis_mark_electric_fence
-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_mark_electric_fence');

-- ==============================================
-- 函数名：gis_mark_electric_fence
-- 功能描述：查询公共电子围栏和项目专属电子围栏，按围栏范围定位网格并写入阻塞标记。
-- 标记规则：bo_electric_fence 写入 block_mask & 1；gis_electric_fence_<project_id> 写入 block_mask & 32。
-- 参数：p_project_id 项目ID；为空时使用默认网格表 gis_grid_nodes。
-- 返回值：标准 TABLE 结构，包含 code、table_name、msg、count。
-- ==============================================
CREATE OR REPLACE FUNCTION gis_mark_electric_fence(p_project_id VARCHAR DEFAULT '')
RETURNS TABLE (code integer, table_name text, msg text, count bigint)
LANGUAGE plpgsql AS $$
DECLARE
    v_start_time timestamptz := clock_timestamp();
    v_table TEXT;
    v_updated_rows BIGINT := 0;
    v_cleared_rows BIGINT := 0;
    v_step_start timestamptz;
    v_extent box3d;
    v_col_exists boolean;
    v_geom_col TEXT;
    v_project_fence_table TEXT;
    v_project_fence_regclass REGCLASS;
    v_log_sql text;
BEGIN
    v_log_sql := format('SELECT * FROM public.gis_mark_electric_fence(%L);', p_project_id);

    -- 根据项目ID确定目标网格表和项目专属围栏表。
    -- p_project_id 为空时操作默认网格表 gis_grid_nodes，只使用公共围栏数据。
    v_step_start := clock_timestamp();
    IF p_project_id = '' OR p_project_id IS NULL THEN
        v_table := 'gis_grid_nodes';
        v_project_fence_table := NULL;
    ELSE
        v_table := 'gis_grid_nodes_' || regexp_replace(p_project_id, '[^0-9a-zA-Z_]', '', 'g');
        v_project_fence_table := 'gis_electric_fence_' || regexp_replace(p_project_id, '[^0-9a-zA-Z_]', '', 'g');
    END IF;
    table_name := v_table;
    RAISE NOTICE '[gis_mark_electric_fence] table: %, elapsed: %', v_table, clock_timestamp() - v_step_start;

    -- 目标网格表必须存在；不存在时直接返回 400 并记录错误日志。
    IF to_regclass(format('%I.%I', current_schema(), v_table)) IS NULL THEN
        code := 400;
        msg := format('参数错误：网格表不存在：%s，执行时间 %s 秒', v_table, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        count := 0;
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN NEXT;
        RETURN;
    END IF;

    -- 准备网格标记字段。
    -- zone_type 保存禁飞区/管控区文本；block_mask 保存来源 bit；is_flyable 表示当前网格是否可飞。
    v_step_start := clock_timestamp();
    SELECT EXISTS (
        SELECT 1
        FROM information_schema.columns c
        WHERE c.table_schema = current_schema()
          AND c.table_name = v_table
          AND c.column_name = 'zone_type'
    ) INTO v_col_exists;

    IF NOT v_col_exists THEN
        EXECUTE format('ALTER TABLE %I ADD COLUMN zone_type VARCHAR(20);', v_table);
    END IF;
    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS block_mask INT DEFAULT 0;', v_table);
    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS is_flyable BOOLEAN DEFAULT true;', v_table);

    -- 电子围栏判断只需要平面几何。
    -- 优先使用 geom2d；旧表没有 geom2d 时使用 geom，并为 z=0 平面网格创建空间索引。
    SELECT CASE WHEN EXISTS (
        SELECT 1
        FROM information_schema.columns c
        WHERE c.table_schema = current_schema()
          AND c.table_name = v_table
          AND c.column_name = 'geom2d'
    ) THEN 'geom2d' ELSE 'geom' END INTO v_geom_col;
    EXECUTE format(
        'CREATE INDEX IF NOT EXISTS %I ON %I USING GIST (%I) WHERE z = 0;',
        'idx_' || substr(md5(v_table), 1, 12) || '_' || v_geom_col || '_z0',
        v_table,
        v_geom_col
    );
    RAISE NOTICE '[gis_mark_electric_fence] prepare columns elapsed: %', clock_timestamp() - v_step_start;

    -- 物化本次参与打标的围栏。
    -- 后续网格空间匹配只访问临时表，避免反复扫描业务围栏表。
    v_step_start := clock_timestamp();
    DROP TABLE IF EXISTS tmp_mark_electric_fence;
    CREATE TEMP TABLE tmp_mark_electric_fence (
        id text,
        source_table text,
        priority int,
        zone_type varchar(20),
        max_height double precision,
        geom4326 geometry(Geometry,4326)
    ) ON COMMIT DROP;

    -- 写入公共围栏 bo_electric_fence。
    -- 只处理有效的禁飞区/管控区：del_flag=false、status=1、fence_type in (1,2)。
    -- height 为 NULL 或 0 时表示不限制高度。
    INSERT INTO tmp_mark_electric_fence (
        id, source_table, priority, zone_type, max_height, geom4326
    )
    SELECT
        id::text,
        'bo_electric_fence',
        CASE fence_type WHEN '1' THEN 10 WHEN '2' THEN 20 END AS priority,
        CASE fence_type
            WHEN '1' THEN '禁飞区'
            WHEN '2' THEN '管控区'
        END::varchar(20) AS zone_type,
        NULLIF(COALESCE(height, 0), 0)::double precision AS max_height,
        ST_SetSRID(ST_Force2D(geom), 4326) AS geom4326
    FROM bo_electric_fence
    WHERE del_flag = false
      AND status = '1'
      AND geom IS NOT NULL
      AND fence_type IN ('1','2')
      AND (COALESCE(p_project_id, '') = '' OR project_id::text = p_project_id::text);

    -- 写入项目专属围栏 gis_electric_fence_<project_id>。
    -- 项目表不存在时跳过，不影响公共围栏打标。
    IF v_project_fence_table IS NOT NULL THEN
        SELECT to_regclass(format('%I.%I', current_schema(), v_project_fence_table)) INTO v_project_fence_regclass;
        IF v_project_fence_regclass IS NOT NULL THEN
            EXECUTE format('
                INSERT INTO tmp_mark_electric_fence (
                    id, source_table, priority, zone_type, max_height, geom4326
                )
                SELECT
                    id::text,
                    %L,
                    CASE fence_type WHEN ''1'' THEN 10 WHEN ''2'' THEN 20 END AS priority,
                    CASE fence_type
                        WHEN ''1'' THEN ''禁飞区''
                        WHEN ''2'' THEN ''管控区''
                    END::varchar(20) AS zone_type,
                    NULLIF(COALESCE(height, 0), 0)::double precision AS max_height,
                    ST_SetSRID(ST_Force2D(geom), 4326) AS geom4326
                FROM %s
                WHERE geom IS NOT NULL
                  AND fence_type IN (''1'',''2'')
            ', v_project_fence_table, v_project_fence_regclass);
        END IF;
    END IF;

    CREATE INDEX IF NOT EXISTS idx_tmp_mark_electric_fence_geom ON tmp_mark_electric_fence USING GIST (geom4326);
    ANALYZE tmp_mark_electric_fence;

    SELECT ST_Extent(geom4326) INTO v_extent FROM tmp_mark_electric_fence;

    -- 没有任何有效围栏时，清空网格表中的电子围栏标记。
    -- 只清 bit 1 和 bit 32，不影响其他模块写入的 block_mask 位。
    IF v_extent IS NULL THEN
        EXECUTE format('
            UPDATE %I
            SET
                zone_type = NULL,
                block_mask = COALESCE(block_mask, 0) & ~33,
                is_flyable = ((COALESCE(block_mask, 0) & ~33) = 0)
            WHERE zone_type IS NOT NULL
               OR (COALESCE(block_mask, 0) & 33) <> 0
        ', v_table);
        GET DIAGNOSTICS v_cleared_rows = ROW_COUNT;
        count := v_cleared_rows;
        code := 200;
        msg := format('无有效电子围栏，已清空 %s 条标记，执行时间 %s 秒', v_cleared_rows, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        RETURN NEXT;
        RETURN;
    END IF;
    RAISE NOTICE '[gis_mark_electric_fence] materialize fences elapsed: %', clock_timestamp() - v_step_start;

    -- 计算每个网格点应该写入的最终围栏标记。
    -- 先只拿 z=0 的平面网格做 ST_Intersects，减少三维高度层重复空间计算。
    -- 再通过 x/y 回连所有高度层，并用 max_height 判断高度是否受围栏影响。
    v_step_start := clock_timestamp();
    DROP TABLE IF EXISTS tmp_mark_desired_zone;
    EXECUTE format('
        CREATE TEMP TABLE tmp_mark_desired_zone ON COMMIT DROP AS
        WITH xy_match AS MATERIALIZED (
            SELECT
                n.x,
                n.y,
                f.zone_type,
                f.max_height,
                f.priority,
                f.id AS fence_id,
                CASE WHEN f.source_table = ''bo_electric_fence'' THEN 1 ELSE 32 END AS block_bit
            FROM (
                SELECT DISTINCT x, y, %I AS geom2d
                FROM %I
                WHERE z = 0
                  AND %I && ST_MakeEnvelope($1, $2, $3, $4, 4326)
            ) n
            JOIN tmp_mark_electric_fence f
              ON n.geom2d && f.geom4326
             AND ST_Intersects(n.geom2d, f.geom4326)
        )
        SELECT
            n.id,
            (array_agg(xy.zone_type ORDER BY xy.priority, xy.fence_id))[1]::varchar(20) AS zone_type,
            bit_or(xy.block_bit) AS block_bit
        FROM %I n
        JOIN xy_match xy
          ON n.x = xy.x
         AND n.y = xy.y
        WHERE xy.max_height IS NULL
           OR n.alt <= xy.max_height
        GROUP BY n.id
    ', v_geom_col, v_table, v_geom_col, v_table)
    USING ST_XMin(v_extent), ST_YMin(v_extent), ST_XMax(v_extent), ST_YMax(v_extent);

    CREATE INDEX IF NOT EXISTS idx_tmp_mark_desired_zone_id ON tmp_mark_desired_zone(id);
    ANALYZE tmp_mark_desired_zone;

    -- 写入命中围栏的网格。
    -- 多个围栏重叠时，zone_type 取优先级最高的围栏，block_mask 用 bit_or 合并来源。
    -- IS DISTINCT FROM 避免重复更新未变化的行。
    EXECUTE format('
        UPDATE %I n
        SET
            zone_type = t.zone_type,
            block_mask = (COALESCE(n.block_mask, 0) & ~33) | t.block_bit,
            is_flyable = false
        FROM tmp_mark_desired_zone t
        WHERE n.id = t.id
          AND (
              n.zone_type IS DISTINCT FROM t.zone_type
              OR n.block_mask IS DISTINCT FROM ((COALESCE(n.block_mask, 0) & ~33) | t.block_bit)
              OR n.is_flyable IS DISTINCT FROM false
          )
    ', v_table);
    GET DIAGNOSTICS v_updated_rows = ROW_COUNT;

    -- 清空不再命中任何有效围栏的旧标记。
    -- 这里是全表级清理：凡是不在 tmp_mark_desired_zone 中的电子围栏标记都会被清掉。
    EXECUTE format('
        UPDATE %I n
        SET
            zone_type = NULL,
            block_mask = COALESCE(n.block_mask, 0) & ~33,
            is_flyable = ((COALESCE(n.block_mask, 0) & ~33) = 0)
        WHERE (n.zone_type IS NOT NULL OR (COALESCE(n.block_mask, 0) & 33) <> 0)
          AND NOT EXISTS (SELECT 1 FROM tmp_mark_desired_zone t WHERE t.id = n.id)
    ', v_table);
    GET DIAGNOSTICS v_cleared_rows = ROW_COUNT;

    count := v_updated_rows + v_cleared_rows;
    code := 200;
    msg := format('电子围栏标记完成，更新 %s 条，清空 %s 条，执行时间 %s 秒', v_updated_rows, v_cleared_rows, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    RAISE NOTICE '[gis_mark_electric_fence] update elapsed: %, affected: %', clock_timestamp() - v_step_start, count;
    RETURN NEXT;

EXCEPTION WHEN OTHERS THEN
    code := 500;
    msg := format('执行异常：%s，执行时间 %s 秒', SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    count := 0;
    table_name := v_table;
    RAISE NOTICE '[gis_mark_electric_fence] error: %', SQLERRM;
    INSERT INTO public.gis_error_log(code, msg, sqlstring)
    VALUES (code, msg, v_log_sql);
    RETURN NEXT;
END;
$$;
COMMENT ON FUNCTION gis_mark_electric_fence(VARCHAR) IS '标记网格电子围栏障碍';

-- ============================================================ gis_refresh_electric_fence
-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_refresh_electric_fence');

-- ==============================================
-- 函数名：gis_refresh_electric_fence
-- 功能描述：刷新项目三维网格的电子围栏标记。
-- 参数：
--   p_project_id   项目ID，必填。
--   p_refresh_json 刷新动作 JSON 文本，可选；NULL 表示全量刷新，传 action/fence_id/geojson 表示局部刷新。
--                  对接接口建议调用拆参函数：
--                  gis_refresh_electric_fence_add(project_id, fence_id, geojson_text)
--                  gis_refresh_electric_fence_delete(project_id, fence_id)
--                  gis_refresh_electric_fence_edit(project_id, fence_id, old_geojson_text, new_geojson_text)
-- 返回值：
--   code        integer     返回码：200 成功，400 参数错误，500 执行异常。
--   table_name  text        操作的网格表名。
--   msg         text        结果描述。
--   count       bigint      本次实际更新或清空的记录数。
-- 刷新规则：
--   1. 全量刷新：先清空电子围栏标记，再调用 gis_mark_electric_fence 重新打标。
--   2. 局部刷新：按 fence_id/action/geojson/old_geojson 确定影响范围，只重算范围内禁飞区/管控区网格。
--   3. 删除场景：优先使用 JSON 中的 geojson；未传时按 fence_id 查询旧 geom。
-- ==============================================
CREATE OR REPLACE FUNCTION gis_refresh_electric_fence(
    p_project_id VARCHAR DEFAULT '',
    p_refresh_json text DEFAULT NULL
)
RETURNS TABLE (
    code integer,
    table_name text,
    msg text,
    count bigint
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_table TEXT;
    v_updated_match_rows BIGINT := 0;
    v_cleared_rows BIGINT := 0;
    v_geom_col TEXT;
    v_project_fence_table TEXT;
    v_project_fence_regclass REGCLASS;
    v_scope_extent box3d;
    v_fence_id varchar;
    v_is_partial boolean;
    v_start_time timestamptz := clock_timestamp();
    v_action text;
    v_fence_type text;
    v_new_geojson jsonb;
    v_old_geojson jsonb;
    v_refresh_json jsonb;
    v_scope_geom geometry(Geometry,4326);
    v_log_sql text;                 -- current function call SQL for error logging
BEGIN
    -- 先把外部传入的 JSON 文本解析成 jsonb。
    -- 这里单独捕获异常，是为了让非法 JSON 文本返回标准 TABLE 结构并写入错误日志。
    BEGIN
        v_refresh_json := CASE
            WHEN p_refresh_json IS NULL OR btrim(p_refresh_json) = '' THEN NULL
            ELSE p_refresh_json::jsonb
        END;
    EXCEPTION WHEN OTHERS THEN
        code := 400;
        table_name := '';
        msg := format('参数错误：refresh_json不是合法JSON文本：%s', SQLERRM);
        count := 0;
        v_log_sql := format('SELECT * FROM public.gis_refresh_electric_fence(%L, %L);',
            p_project_id, p_refresh_json);
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN NEXT;
        RETURN;
    END;

    -- 从 JSON 中兼容读取围栏 ID 和动作类型。
    -- 只传 fence_id 时也视为局部刷新；不传 JSON 或 JSON 为空时走全量刷新。
    v_fence_id := COALESCE(
        v_refresh_json ->> 'fence_id',
        v_refresh_json ->> 'fenceId',
        v_refresh_json ->> 'id'
    );
    v_action := lower(COALESCE(
        v_refresh_json ->> 'action',
        v_refresh_json ->> 'operate',
        v_refresh_json ->> 'operation',
        v_refresh_json ->> 'type',
        ''
    ));
    v_is_partial := v_refresh_json IS NOT NULL
        AND (
            COALESCE(NULLIF(btrim(v_fence_id), ''), '') <> ''
            OR COALESCE(NULLIF(btrim(v_action), ''), '') <> ''
        );

    v_log_sql := format('SELECT * FROM public.gis_refresh_electric_fence(%L, %L);',
        p_project_id, p_refresh_json);

    IF p_project_id IS NULL OR btrim(p_project_id) = '' THEN
        code := 400;
        table_name := '';
        msg := format('参数错误：项目ID不能为空，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        count := 0;
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN NEXT;
        RETURN;
    END IF;

    v_table := 'gis_grid_nodes_' || regexp_replace(p_project_id, '[^0-9a-zA-Z_]', '', 'g');
    v_project_fence_table := 'gis_electric_fence_' || regexp_replace(p_project_id, '[^0-9a-zA-Z_]', '', 'g');
    table_name := v_table;
    SELECT to_regclass(format('%I.%I', current_schema(), v_project_fence_table)) INTO v_project_fence_regclass;

    IF v_project_fence_regclass IS NULL THEN
        code := 500;
        msg := format('执行异常：电子围栏表不存在：%s，执行时间 %s 秒', v_project_fence_table, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        count := 0;
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN NEXT;
        RETURN;
    END IF;

    IF to_regclass(format('%I.%I', current_schema(), v_table)) IS NULL THEN
        code := 500;
        msg := format('执行异常：网格表不存在：%s，执行时间 %s 秒', v_table, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        count := 0;
        INSERT INTO public.gis_error_log(code, msg, sqlstring)
        VALUES (code, msg, v_log_sql);
        RETURN NEXT;
        RETURN;
    END IF;

    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS zone_type VARCHAR(20);', v_table);
    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS block_mask INT DEFAULT 0;', v_table);
    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS is_flyable BOOLEAN DEFAULT true;', v_table);

    -- 网格表可能同时存在 geom 和 geom2d。
    -- 电子围栏只做平面范围判断，优先使用 geom2d，没有则回退到 geom。
    SELECT CASE WHEN EXISTS (
        SELECT 1
        FROM information_schema.columns c
        WHERE c.table_schema = current_schema()
          AND c.table_name = v_table
          AND c.column_name = 'geom2d'
    ) THEN 'geom2d' ELSE 'geom' END INTO v_geom_col;
    EXECUTE format(
        'CREATE INDEX IF NOT EXISTS %I ON %I USING GIST (%I) WHERE z = 0;',
        'idx_' || substr(md5(v_table), 1, 12) || '_' || v_geom_col || '_z0',
        v_table,
        v_geom_col
    );

    -- 全量刷新：先清空电子围栏相关标记位，再调用 gis_mark_electric_fence 重新打标。
    -- block_mask 中 bit 1 表示公共围栏，bit 32 表示项目专属围栏；~33 用于只清这两类标记。
    IF NOT v_is_partial THEN
        EXECUTE format('
            UPDATE %I
            SET
                zone_type = NULL,
                block_mask = COALESCE(block_mask, 0) & ~33,
                is_flyable = ((COALESCE(block_mask, 0) & ~33) = 0)
            WHERE zone_type IS NOT NULL
               OR (COALESCE(block_mask, 0) & 33) <> 0
        ', v_table);
        GET DIAGNOSTICS v_cleared_rows = ROW_COUNT;

        RETURN QUERY
        SELECT
            m.code,
            m.table_name,
            format('已清空 %s 条电子围栏标记；%s', v_cleared_rows, m.msg)::text AS msg,
            (v_cleared_rows + COALESCE(m.count, 0))::bigint AS count
        FROM gis_mark_electric_fence(p_project_id) AS m;
        RETURN;
    END IF;

    -- 局部刷新临时表：
    -- tmp_refresh_electric_fence 保存本次刷新范围内仍然有效、需要参与重算的围栏。
    -- tmp_refresh_scope_fence 保存本次需要重算的空间范围，来源可以是新/旧 GeoJSON 或 fence_id 查到的旧 geom。
    DROP TABLE IF EXISTS tmp_refresh_electric_fence;
    CREATE TEMP TABLE tmp_refresh_electric_fence (
        id text,
        source_table text,
        priority int,
        zone_type varchar(20),
        max_height double precision,
        geom4326 geometry(Geometry,4326)
    ) ON COMMIT DROP;

    DROP TABLE IF EXISTS tmp_refresh_scope_fence;
    CREATE TEMP TABLE tmp_refresh_scope_fence (
        geom4326 geometry(Geometry,4326)
    ) ON COMMIT DROP;

    IF v_is_partial THEN
        IF v_refresh_json IS NOT NULL THEN
            -- 解析局部刷新动作。GeoJSON 字段兼容多种命名，方便接口侧传参。
            v_fence_type := COALESCE(v_refresh_json ->> 'fence_type', v_refresh_json ->> 'fenceType');
            v_new_geojson := COALESCE(
                v_refresh_json -> 'geojson',
                v_refresh_json -> 'geom',
                v_refresh_json -> 'geometry',
                v_refresh_json -> 'new_geojson',
                v_refresh_json -> 'newGeom',
                v_refresh_json -> 'new_geometry'
            );
            v_old_geojson := COALESCE(
                v_refresh_json -> 'old_geojson',
                v_refresh_json -> 'oldGeom',
                v_refresh_json -> 'old_geometry'
            );

            IF v_action IN ('add', 'insert', 'create', '新增') THEN
                -- 新增：只需要用新 GeoJSON 作为局部刷新范围。
                -- 围栏数据本身不在这里插入，本函数只负责刷新网格标记。
                IF v_new_geojson IS NULL THEN
                    code := 400;
                    msg := format('参数错误：新增刷新必须提供geojson，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
                    count := 0;
                    INSERT INTO public.gis_error_log(code, msg, sqlstring)
                    VALUES (code, msg, v_log_sql);
                    RETURN NEXT;
                    RETURN;
                END IF;

                -- 将 GeoJSON 解析为 4326 平面几何，并校验必须是非空、有效的面。
                BEGIN
                    v_scope_geom := ST_SetSRID(ST_Force2D(ST_GeomFromGeoJSON(CASE WHEN v_new_geojson ->> 'type' = 'Feature' THEN v_new_geojson ->> 'geometry' ELSE v_new_geojson::text END)), 4326);
                EXCEPTION WHEN OTHERS THEN
                    code := 400;
                    msg := format('参数错误：新增geojson格式错误：%s，执行时间 %s 秒', SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
                    count := 0;
                    INSERT INTO public.gis_error_log(code, msg, sqlstring)
                    VALUES (code, msg, v_log_sql);
                    RETURN NEXT;
                    RETURN;
                END;

                IF ST_IsEmpty(v_scope_geom) THEN
                    code := 400;
                    msg := format('参数错误：新增geojson不能为空几何，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
                    count := 0;
                    INSERT INTO public.gis_error_log(code, msg, sqlstring)
                    VALUES (code, msg, v_log_sql);
                    RETURN NEXT;
                    RETURN;
                END IF;

                IF ST_GeometryType(v_scope_geom) NOT IN ('ST_Polygon', 'ST_MultiPolygon') THEN
                    code := 400;
                    msg := format('参数错误：新增geojson必须是Polygon或MultiPolygon，当前为%s，执行时间 %s 秒', ST_GeometryType(v_scope_geom), ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
                    count := 0;
                    INSERT INTO public.gis_error_log(code, msg, sqlstring)
                    VALUES (code, msg, v_log_sql);
                    RETURN NEXT;
                    RETURN;
                END IF;

                IF NOT ST_IsValid(v_scope_geom) THEN
                    code := 400;
                    msg := format('参数错误：新增geojson几何无效：%s，执行时间 %s 秒', ST_IsValidReason(v_scope_geom), ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
                    count := 0;
                    INSERT INTO public.gis_error_log(code, msg, sqlstring)
                    VALUES (code, msg, v_log_sql);
                    RETURN NEXT;
                    RETURN;
                END IF;

                INSERT INTO tmp_refresh_scope_fence (geom4326)
                VALUES (v_scope_geom);

            ELSIF v_action IN ('edit', 'update', 'modify', '编辑') THEN
                -- 编辑：用新范围和旧范围的并集做局部刷新。
                -- 这样既能标记新增覆盖区域，也能清理旧范围中不再被覆盖的网格。
                IF v_new_geojson IS NULL THEN
                    code := 400;
                    msg := format('参数错误：编辑刷新必须提供geojson，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
                    count := 0;
                    INSERT INTO public.gis_error_log(code, msg, sqlstring)
                    VALUES (code, msg, v_log_sql);
                    RETURN NEXT;
                    RETURN;
                END IF;

                IF v_new_geojson IS NOT NULL THEN
                    -- 新 GeoJSON 负责刷新编辑后的覆盖范围。
                    BEGIN
                        v_scope_geom := ST_SetSRID(ST_Force2D(ST_GeomFromGeoJSON(CASE WHEN v_new_geojson ->> 'type' = 'Feature' THEN v_new_geojson ->> 'geometry' ELSE v_new_geojson::text END)), 4326);
                    EXCEPTION WHEN OTHERS THEN
                        code := 400;
                        msg := format('参数错误：编辑新geojson格式错误：%s，执行时间 %s 秒', SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
                        count := 0;
                        INSERT INTO public.gis_error_log(code, msg, sqlstring)
                        VALUES (code, msg, v_log_sql);
                        RETURN NEXT;
                        RETURN;
                    END;
                    IF ST_IsEmpty(v_scope_geom) OR ST_GeometryType(v_scope_geom) NOT IN ('ST_Polygon', 'ST_MultiPolygon') OR NOT ST_IsValid(v_scope_geom) THEN
                        code := 400;
                        msg := format('参数错误：编辑新geojson必须是非空有效Polygon或MultiPolygon，当前类型%s，有效性：%s，执行时间 %s 秒', ST_GeometryType(v_scope_geom), ST_IsValidReason(v_scope_geom), ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
                        count := 0;
                        INSERT INTO public.gis_error_log(code, msg, sqlstring)
                        VALUES (code, msg, v_log_sql);
                        RETURN NEXT;
                        RETURN;
                    END IF;
                    INSERT INTO tmp_refresh_scope_fence (geom4326)
                    VALUES (v_scope_geom);
                END IF;

                IF v_old_geojson IS NOT NULL THEN
                    -- 旧 GeoJSON 负责刷新编辑前的覆盖范围，避免旧标记残留。
                    BEGIN
                        v_scope_geom := ST_SetSRID(ST_Force2D(ST_GeomFromGeoJSON(CASE WHEN v_old_geojson ->> 'type' = 'Feature' THEN v_old_geojson ->> 'geometry' ELSE v_old_geojson::text END)), 4326);
                    EXCEPTION WHEN OTHERS THEN
                        code := 400;
                        msg := format('参数错误：编辑旧geojson格式错误：%s，执行时间 %s 秒', SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
                        count := 0;
                        INSERT INTO public.gis_error_log(code, msg, sqlstring)
                        VALUES (code, msg, v_log_sql);
                        RETURN NEXT;
                        RETURN;
                    END;
                    IF ST_IsEmpty(v_scope_geom) OR ST_GeometryType(v_scope_geom) NOT IN ('ST_Polygon', 'ST_MultiPolygon') OR NOT ST_IsValid(v_scope_geom) THEN
                        code := 400;
                        msg := format('参数错误：编辑旧geojson必须是非空有效Polygon或MultiPolygon，当前类型%s，有效性：%s，执行时间 %s 秒', ST_GeometryType(v_scope_geom), ST_IsValidReason(v_scope_geom), ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
                        count := 0;
                        INSERT INTO public.gis_error_log(code, msg, sqlstring)
                        VALUES (code, msg, v_log_sql);
                        RETURN NEXT;
                        RETURN;
                    END IF;
                    INSERT INTO tmp_refresh_scope_fence (geom4326)
                    VALUES (v_scope_geom);
                END IF;

            ELSIF v_action IN ('delete', 'remove', 'del', '删除') THEN
                -- 删除：如果调用方传了旧 GeoJSON，则优先用旧 GeoJSON 确定刷新范围。
                -- 如果没传，后面会按 fence_id 从围栏表中查询旧 geom。
                IF v_new_geojson IS NOT NULL THEN
                    BEGIN
                        v_scope_geom := ST_SetSRID(ST_Force2D(ST_GeomFromGeoJSON(CASE WHEN v_new_geojson ->> 'type' = 'Feature' THEN v_new_geojson ->> 'geometry' ELSE v_new_geojson::text END)), 4326);
                    EXCEPTION WHEN OTHERS THEN
                        code := 400;
                        msg := format('参数错误：删除geojson格式错误：%s，执行时间 %s 秒', SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
                        count := 0;
                        INSERT INTO public.gis_error_log(code, msg, sqlstring)
                        VALUES (code, msg, v_log_sql);
                        RETURN NEXT;
                        RETURN;
                    END;
                    IF ST_IsEmpty(v_scope_geom) OR ST_GeometryType(v_scope_geom) NOT IN ('ST_Polygon', 'ST_MultiPolygon') OR NOT ST_IsValid(v_scope_geom) THEN
                        code := 400;
                        msg := format('参数错误：删除geojson必须是非空有效Polygon或MultiPolygon，当前类型%s，有效性：%s，执行时间 %s 秒', ST_GeometryType(v_scope_geom), ST_IsValidReason(v_scope_geom), ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
                        count := 0;
                        INSERT INTO public.gis_error_log(code, msg, sqlstring)
                        VALUES (code, msg, v_log_sql);
                        RETURN NEXT;
                        RETURN;
                    END IF;
                    INSERT INTO tmp_refresh_scope_fence (geom4326)
                    VALUES (v_scope_geom);
                END IF;
            ELSE
                code := 400;
                msg := format('参数错误：refresh_json.action必须是新增/编辑/删除，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
                count := 0;
                INSERT INTO public.gis_error_log(code, msg, sqlstring)
                VALUES (code, msg, v_log_sql);
                RETURN NEXT;
                RETURN;
            END IF;

            IF v_fence_type IS NOT NULL AND v_fence_type NOT IN ('1', '2', '3') THEN
                code := 400;
                msg := format('参数错误：fence_type必须是1/2/3，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
                count := 0;
                INSERT INTO public.gis_error_log(code, msg, sqlstring)
                VALUES (code, msg, v_log_sql);
                RETURN NEXT;
                RETURN;
            END IF;
        END IF;

        -- 兼容只传 fence_id 的局部刷新。
        -- 从公共围栏表和项目专属围栏表查旧 geom，一并加入刷新范围。
        INSERT INTO tmp_refresh_scope_fence (geom4326)
        SELECT ST_SetSRID(ST_Force2D(geom), 4326) AS geom4326
        FROM bo_electric_fence
        WHERE id::text = v_fence_id::text
          AND geom IS NOT NULL
          AND (COALESCE(p_project_id, '') = '' OR project_id::TEXT = p_project_id::TEXT);

        IF v_project_fence_table IS NOT NULL AND v_project_fence_regclass IS NOT NULL THEN
            EXECUTE format('
                INSERT INTO tmp_refresh_scope_fence (geom4326)
                SELECT ST_SetSRID(ST_Force2D(geom), 4326) AS geom4326
                FROM %s
                WHERE id::text = $1
                  AND geom IS NOT NULL
            ', v_project_fence_regclass)
            USING v_fence_id;
        END IF;

        -- 用所有范围几何的外包框作为本次局部刷新范围。
        -- 如果范围为空，说明既没有有效 GeoJSON，也没能按 fence_id 找到旧 geom。
        SELECT ST_Extent(geom4326) INTO v_scope_extent FROM tmp_refresh_scope_fence;

        IF v_scope_extent IS NULL THEN
            code := 400;
            msg := format('参数错误：未找到可刷新的电子围栏或围栏无geom：%s，执行时间 %s 秒', v_fence_id, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
            count := 0;
            INSERT INTO public.gis_error_log(code, msg, sqlstring)
            VALUES (code, msg, v_log_sql);
            RETURN NEXT;
            RETURN;
        END IF;
    END IF;

    -- 收集本次刷新范围内仍然有效的公共围栏。
    -- 后续不是简单清空旧范围，而是根据这些有效围栏重新计算网格最终标记，避免误清重叠围栏。
    INSERT INTO tmp_refresh_electric_fence (
        id, source_table, priority, zone_type, max_height, geom4326
    )
    SELECT
        id::text,
        'bo_electric_fence',
        CASE fence_type WHEN '1' THEN 10 WHEN '2' THEN 20 END AS priority,
        CASE fence_type
            WHEN '1' THEN '禁飞区'
            WHEN '2' THEN '管控区'
        END::varchar(20) AS zone_type,
        NULLIF(COALESCE(height, 0), 0)::double precision AS max_height,
        ST_SetSRID(ST_Force2D(geom), 4326) AS geom4326
    FROM bo_electric_fence
    WHERE del_flag = false
      AND status = '1'
      AND geom IS NOT NULL
      AND fence_type IN ('1', '2')
      AND (COALESCE(p_project_id, '') = '' OR project_id::TEXT = p_project_id::TEXT)
      AND (
          NOT v_is_partial
          OR ST_SetSRID(ST_Force2D(geom), 4326) && ST_MakeEnvelope(
              ST_XMin(v_scope_extent), ST_YMin(v_scope_extent),
              ST_XMax(v_scope_extent), ST_YMax(v_scope_extent), 4326
          )
      );

    IF v_project_fence_table IS NOT NULL THEN
        IF v_project_fence_regclass IS NOT NULL THEN
            -- 收集本次刷新范围内仍然有效的项目专属围栏。
            -- source_table 用于区分 block_mask 写 bit 1 还是 bit 32。
            EXECUTE format('
                INSERT INTO tmp_refresh_electric_fence (
                    id, source_table, priority, zone_type, max_height, geom4326
                )
                SELECT
                    id::text,
                    %L,
                    CASE fence_type WHEN ''1'' THEN 10 WHEN ''2'' THEN 20 END AS priority,
                    CASE fence_type
                        WHEN ''1'' THEN ''禁飞区''
                        WHEN ''2'' THEN ''管控区''
                    END::varchar(20) AS zone_type,
                    NULLIF(COALESCE(height, 0), 0)::double precision AS max_height,
                    ST_SetSRID(ST_Force2D(geom), 4326) AS geom4326
                FROM %s
                WHERE geom IS NOT NULL
                  AND fence_type IN (''1'',''2'')
                  AND (
                      NOT $1
                      OR ST_SetSRID(ST_Force2D(geom), 4326) && ST_MakeEnvelope($2, $3, $4, $5, 4326)
                  )
            ', v_project_fence_table, v_project_fence_regclass)
            USING v_is_partial,
                  CASE WHEN v_scope_extent IS NULL THEN NULL ELSE ST_XMin(v_scope_extent) END,
                  CASE WHEN v_scope_extent IS NULL THEN NULL ELSE ST_YMin(v_scope_extent) END,
                  CASE WHEN v_scope_extent IS NULL THEN NULL ELSE ST_XMax(v_scope_extent) END,
                  CASE WHEN v_scope_extent IS NULL THEN NULL ELSE ST_YMax(v_scope_extent) END;
        END IF;
    END IF;

    CREATE INDEX IF NOT EXISTS idx_tmp_refresh_electric_fence_geom ON tmp_refresh_electric_fence USING GIST (geom4326);
    ANALYZE tmp_refresh_electric_fence;

    IF NOT v_is_partial THEN
        SELECT ST_Extent(geom4326) INTO v_scope_extent FROM tmp_refresh_electric_fence;
    END IF;

    -- 如果当前没有任何有效围栏，则清空电子围栏相关标记。
    IF v_scope_extent IS NULL THEN
        EXECUTE format('
            UPDATE %I
            SET
                zone_type = NULL,
                block_mask = COALESCE(block_mask, 0) & ~33,
                is_flyable = ((COALESCE(block_mask, 0) & ~33) = 0)
            WHERE zone_type IS NOT NULL
               OR (COALESCE(block_mask, 0) & 33) <> 0
        ', v_table);
        GET DIAGNOSTICS v_cleared_rows = ROW_COUNT;
        count := v_cleared_rows;
        code := 200;
        msg := format('无有效电子围栏，已清空 %s 条标记，执行时间 %s 秒', v_cleared_rows, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        RETURN NEXT;
        RETURN;
    END IF;

    -- 先缩小到刷新范围内的 z=0 平面网格点。
    -- 后续再通过 x/y 关联所有高度层，避免每个高度层重复做空间相交判断。
    DROP TABLE IF EXISTS tmp_refresh_scope_xy;
    EXECUTE format('
        CREATE TEMP TABLE tmp_refresh_scope_xy ON COMMIT DROP AS
        SELECT DISTINCT x, y, %I AS geom2d
        FROM %I
        WHERE z = 0
          AND %I && ST_MakeEnvelope($1, $2, $3, $4, 4326)
    ', v_geom_col, v_table, v_geom_col)
    USING ST_XMin(v_scope_extent), ST_YMin(v_scope_extent), ST_XMax(v_scope_extent), ST_YMax(v_scope_extent);

    CREATE INDEX IF NOT EXISTS idx_tmp_refresh_scope_xy ON tmp_refresh_scope_xy (x, y);
    ANALYZE tmp_refresh_scope_xy;

    -- 计算每个网格点最终应该拥有的电子围栏标记。
    -- 多个围栏重叠时，按 priority 和 fence_id 取最高优先级 zone_type，同时 bit_or 合并来源标记位。
    DROP TABLE IF EXISTS tmp_desired_zone;
    EXECUTE format('
        CREATE TEMP TABLE tmp_desired_zone ON COMMIT DROP AS
        WITH xy_match AS MATERIALIZED (
            SELECT
                n.x,
                n.y,
                f.zone_type,
                f.max_height,
                f.priority,
                f.id AS fence_id,
                CASE WHEN f.source_table = ''bo_electric_fence'' THEN 1 ELSE 32 END AS block_bit
            FROM (
                SELECT x, y, geom2d
                FROM tmp_refresh_scope_xy
            ) n
            JOIN tmp_refresh_electric_fence f
              ON n.geom2d && f.geom4326
             AND ST_Intersects(n.geom2d, f.geom4326)
        )
        SELECT
            n.id,
            (array_agg(xy.zone_type ORDER BY xy.priority, xy.fence_id))[1]::varchar(20) AS zone_type,
            bit_or(xy.block_bit) AS block_bit
        FROM %I n
        JOIN xy_match xy
          ON n.x = xy.x
         AND n.y = xy.y
        WHERE xy.max_height IS NULL
           OR n.alt <= xy.max_height
        GROUP BY n.id
    ', v_table);

    EXECUTE 'CREATE INDEX IF NOT EXISTS idx_tmp_desired_zone_id ON tmp_desired_zone(id);';
    EXECUTE 'ANALYZE tmp_desired_zone;';

    -- 写入仍然命中有效围栏的网格。
    -- WHERE 中使用 IS DISTINCT FROM，只更新实际发生变化的行，减少无效写入。
    EXECUTE format('
        UPDATE %I n
        SET
            zone_type = t.zone_type,
            block_mask = (COALESCE(n.block_mask, 0) & ~33) | t.block_bit,
            is_flyable = false
        FROM tmp_desired_zone t
        WHERE n.id = t.id
          AND (
              n.zone_type IS DISTINCT FROM t.zone_type
              OR n.block_mask IS DISTINCT FROM ((COALESCE(n.block_mask, 0) & ~33) | t.block_bit)
              OR n.is_flyable IS DISTINCT FROM false
          )
    ', v_table);
    GET DIAGNOSTICS v_updated_match_rows = ROW_COUNT;

    -- 清空刷新范围内已经不再命中任何有效围栏的网格。
    -- 只清电子围栏相关 bit，不影响建筑物、DEM 等其他可能占用的 block_mask 位。
    EXECUTE format('
        UPDATE %I n
        SET
            zone_type = NULL,
            block_mask = COALESCE(n.block_mask, 0) & ~33,
            is_flyable = ((COALESCE(n.block_mask, 0) & ~33) = 0)
        WHERE (n.zone_type IS NOT NULL OR (COALESCE(n.block_mask, 0) & 33) <> 0)
          AND EXISTS (SELECT 1 FROM tmp_refresh_scope_xy s WHERE s.x = n.x AND s.y = n.y)
          AND NOT EXISTS (SELECT 1 FROM tmp_desired_zone t WHERE t.id = n.id)
    ', v_table);
    GET DIAGNOSTICS v_cleared_rows = ROW_COUNT;

    count := v_updated_match_rows + v_cleared_rows;
    code := 200;
    msg := CASE
        WHEN v_is_partial THEN format('按围栏 %s 局部刷新完成，更新 %s 条，清空 %s 条，执行时间 %s 秒', v_fence_id, v_updated_match_rows, v_cleared_rows, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))
        ELSE format('按 bo_electric_fence 当前有效数据和项目专属围栏刷新完成，更新 %s 条，清空 %s 条，执行时间 %s 秒', v_updated_match_rows, v_cleared_rows, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))
    END;
    RETURN NEXT;

EXCEPTION WHEN OTHERS THEN
    code := 500;
    table_name := v_table;
    msg := format('刷新失败：%s，执行时间 %s 秒', SQLERRM, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
    count := 0;
    INSERT INTO public.gis_error_log(code, msg, sqlstring)
    VALUES (code, msg, v_log_sql);
    RETURN NEXT;
END;
$$;
COMMENT ON FUNCTION gis_refresh_electric_fence(VARCHAR, text) IS '刷新网格电子围栏标记';

-- ============================================================ gis_refresh_electric_fence_add
SELECT gis_drop_function('gis_refresh_electric_fence_add');

-- 函数名：gis_refresh_electric_fence_add
-- 功能描述：新增电子围栏后，根据新围栏 GeoJSON 做局部刷新。
-- 参数：
--   p_project_id 项目ID，必填。
--   p_fence_id   围栏ID，必填。
--   p_geojson    新围栏 GeoJSON 文本，必填。
CREATE OR REPLACE FUNCTION gis_refresh_electric_fence_add(
    p_project_id VARCHAR,
    p_fence_id VARCHAR,
    p_geojson text
)
RETURNS TABLE (
    code integer,
    table_name text,
    msg text,
    count bigint
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_log_sql text := format('SELECT * FROM public.gis_refresh_electric_fence_add(%L, %L, %L);', p_project_id, p_fence_id, p_geojson);
BEGIN
    -- 对接层拆参函数：先校验必填参数，再组装底层 refresh_json。
    -- GeoJSON 文本在这里先转 jsonb，非法 JSON 会进入异常捕获并写日志。
    IF p_project_id IS NULL OR btrim(p_project_id) = '' THEN
        code := 400;
        table_name := '';
        msg := '参数错误：项目ID不能为空';
        count := 0;
        INSERT INTO public.gis_error_log(code, msg, sqlstring) VALUES (code, msg, v_log_sql);
        RETURN NEXT;
        RETURN;
    END IF;

    IF p_fence_id IS NULL OR btrim(p_fence_id) = '' THEN
        code := 400;
        table_name := '';
        msg := '参数错误：围栏ID不能为空';
        count := 0;
        INSERT INTO public.gis_error_log(code, msg, sqlstring) VALUES (code, msg, v_log_sql);
        RETURN NEXT;
        RETURN;
    END IF;

    IF p_geojson IS NULL OR btrim(p_geojson) = '' THEN
        code := 400;
        table_name := '';
        msg := '参数错误：新增围栏GeoJSON不能为空';
        count := 0;
        INSERT INTO public.gis_error_log(code, msg, sqlstring) VALUES (code, msg, v_log_sql);
        RETURN NEXT;
        RETURN;
    END IF;

    RETURN QUERY
    SELECT *
    FROM gis_refresh_electric_fence(
        p_project_id,
        jsonb_build_object(
            'action', 'add',
            'fence_id', p_fence_id,
            'geojson', p_geojson::jsonb
        )::text
    );
EXCEPTION WHEN OTHERS THEN
    code := 400;
    table_name := '';
    msg := format('参数错误：新增围栏刷新参数异常：%s', SQLERRM);
    count := 0;
    INSERT INTO public.gis_error_log(code, msg, sqlstring) VALUES (code, msg, v_log_sql);
    RETURN NEXT;
END;
$$;
COMMENT ON FUNCTION gis_refresh_electric_fence_add(VARCHAR, VARCHAR, text) IS '新增电子围栏后局部刷新网格电子围栏标记';

-- ============================================================ gis_refresh_electric_fence_delete
SELECT gis_drop_function('gis_refresh_electric_fence_delete');

-- 函数名：gis_refresh_electric_fence_delete
-- 功能描述：删除电子围栏后，根据围栏ID查询旧 geom 并做局部刷新。
-- 参数：
--   p_project_id 项目ID，必填。
--   p_fence_id   围栏ID，必填。
CREATE OR REPLACE FUNCTION gis_refresh_electric_fence_delete(
    p_project_id VARCHAR,
    p_fence_id VARCHAR
)
RETURNS TABLE (
    code integer,
    table_name text,
    msg text,
    count bigint
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_log_sql text := format('SELECT * FROM public.gis_refresh_electric_fence_delete(%L, %L);', p_project_id, p_fence_id);
BEGIN
    -- 删除刷新只需要项目ID和围栏ID。
    -- 底层会按 fence_id 查旧 geom 作为刷新范围，然后重算该范围内的网格标记。
    IF p_project_id IS NULL OR btrim(p_project_id) = '' THEN
        code := 400;
        table_name := '';
        msg := '参数错误：项目ID不能为空';
        count := 0;
        INSERT INTO public.gis_error_log(code, msg, sqlstring) VALUES (code, msg, v_log_sql);
        RETURN NEXT;
        RETURN;
    END IF;

    IF p_fence_id IS NULL OR btrim(p_fence_id) = '' THEN
        code := 400;
        table_name := '';
        msg := '参数错误：围栏ID不能为空';
        count := 0;
        INSERT INTO public.gis_error_log(code, msg, sqlstring) VALUES (code, msg, v_log_sql);
        RETURN NEXT;
        RETURN;
    END IF;

    RETURN QUERY
    SELECT *
    FROM gis_refresh_electric_fence(
        p_project_id,
        jsonb_build_object(
            'action', 'delete',
            'fence_id', p_fence_id
        )::text
    );
EXCEPTION WHEN OTHERS THEN
    code := 500;
    table_name := '';
    msg := format('删除围栏刷新失败：%s', SQLERRM);
    count := 0;
    INSERT INTO public.gis_error_log(code, msg, sqlstring) VALUES (code, msg, v_log_sql);
    RETURN NEXT;
END;
$$;
COMMENT ON FUNCTION gis_refresh_electric_fence_delete(VARCHAR, VARCHAR) IS '删除电子围栏后按围栏ID局部刷新网格电子围栏标记';

-- ============================================================ gis_refresh_electric_fence_edit
SELECT gis_drop_function('gis_refresh_electric_fence_edit');

-- 函数名：gis_refresh_electric_fence_edit
-- 功能描述：编辑电子围栏后，根据旧 GeoJSON 和新 GeoJSON 的共同范围做局部刷新。
-- 参数：
--   p_project_id  项目ID，必填。
--   p_fence_id    围栏ID，必填。
--   p_old_geojson 旧围栏 GeoJSON 文本，必填。
--   p_new_geojson 新围栏 GeoJSON 文本，必填。
CREATE OR REPLACE FUNCTION gis_refresh_electric_fence_edit(
    p_project_id VARCHAR,
    p_fence_id VARCHAR,
    p_old_geojson text,
    p_new_geojson text
)
RETURNS TABLE (
    code integer,
    table_name text,
    msg text,
    count bigint
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_log_sql text := format('SELECT * FROM public.gis_refresh_electric_fence_edit(%L, %L, %L, %L);', p_project_id, p_fence_id, p_old_geojson, p_new_geojson);
BEGIN
    -- 编辑刷新必须同时提供旧 GeoJSON 和新 GeoJSON。
    -- 旧范围用于清理旧标记，新范围用于写入新标记，二者共同决定局部刷新范围。
    IF p_project_id IS NULL OR btrim(p_project_id) = '' THEN
        code := 400;
        table_name := '';
        msg := '参数错误：项目ID不能为空';
        count := 0;
        INSERT INTO public.gis_error_log(code, msg, sqlstring) VALUES (code, msg, v_log_sql);
        RETURN NEXT;
        RETURN;
    END IF;

    IF p_fence_id IS NULL OR btrim(p_fence_id) = '' THEN
        code := 400;
        table_name := '';
        msg := '参数错误：围栏ID不能为空';
        count := 0;
        INSERT INTO public.gis_error_log(code, msg, sqlstring) VALUES (code, msg, v_log_sql);
        RETURN NEXT;
        RETURN;
    END IF;

    IF p_old_geojson IS NULL OR btrim(p_old_geojson) = '' THEN
        code := 400;
        table_name := '';
        msg := '参数错误：旧围栏GeoJSON不能为空';
        count := 0;
        INSERT INTO public.gis_error_log(code, msg, sqlstring) VALUES (code, msg, v_log_sql);
        RETURN NEXT;
        RETURN;
    END IF;

    IF p_new_geojson IS NULL OR btrim(p_new_geojson) = '' THEN
        code := 400;
        table_name := '';
        msg := '参数错误：新围栏GeoJSON不能为空';
        count := 0;
        INSERT INTO public.gis_error_log(code, msg, sqlstring) VALUES (code, msg, v_log_sql);
        RETURN NEXT;
        RETURN;
    END IF;

    RETURN QUERY
    SELECT *
    FROM gis_refresh_electric_fence(
        p_project_id,
        jsonb_build_object(
            'action', 'edit',
            'fence_id', p_fence_id,
            'old_geojson', p_old_geojson::jsonb,
            'geojson', p_new_geojson::jsonb
        )::text
    );
EXCEPTION WHEN OTHERS THEN
    code := 400;
    table_name := '';
    msg := format('参数错误：编辑围栏刷新参数异常：%s', SQLERRM);
    count := 0;
    INSERT INTO public.gis_error_log(code, msg, sqlstring) VALUES (code, msg, v_log_sql);
    RETURN NEXT;
END;
$$;
COMMENT ON FUNCTION gis_refresh_electric_fence_edit(VARCHAR, VARCHAR, text, text) IS '编辑电子围栏后按旧新范围局部刷新网格电子围栏标记';



-- =============================================================================
-- 函数调用示例
-- =============================================================================
-- SELECT * FROM gis_mark_electric_fence('2c95908e958f3b75019593551f520126');

-- 围栏数据发生变更且需要全量刷新时，只传项目ID。
-- SELECT * FROM gis_refresh_electric_fence('2c95908e958f3b75019593551f520126');

-- 也可以显式传 NULL::text 刷新全部区域标记。
-- SELECT * FROM gis_refresh_electric_fence('2c95908e958f3b75019593551f520126', NULL::text);

-- 第二个参数示例1：只传 fence_id，按围栏ID查询旧 geom 并局部刷新。
-- SELECT * FROM gis_refresh_electric_fence(
--     '2c95908e958f3b75019593551f520126',
--     '{"fence_id":"fence_id"}'
-- );

-- 第二个参数示例2：新增围栏，使用新 geojson 确定局部刷新范围。
-- SELECT * FROM gis_refresh_electric_fence(
--     '2c95908e958f3b75019593551f520126',
--     '{"fence_id":"fence_id","action":"add","geojson":{"type":"Polygon","coordinates":[[[113.1,34.1],[113.2,34.1],[113.2,34.2],[113.1,34.2],[113.1,34.1]]]}}'
-- );

-- 第二个参数示例3：编辑围栏，使用旧 geojson 和新 geojson 共同确定局部刷新范围。
-- SELECT * FROM gis_refresh_electric_fence(
--     '2c95908e958f3b75019593551f520126',
--     '{"fence_id":"fence_id","action":"edit","old_geojson":{"type":"Polygon","coordinates":[[[113.1,34.1],[113.2,34.1],[113.2,34.2],[113.1,34.2],[113.1,34.1]]]},"geojson":{"type":"Polygon","coordinates":[[[113.1,34.1],[113.3,34.1],[113.3,34.3],[113.1,34.3],[113.1,34.1]]]}}'
-- );

-- 第二个参数示例4：删除围栏，只传 fence_id 时按表内旧 geom 确定局部刷新范围。
-- SELECT * FROM gis_refresh_electric_fence(
--     '2c95908e958f3b75019593551f520126',
--     '{"fence_id":"fence_id","action":"delete"}'
-- );

-- 第二个参数示例5：删除围栏，同时传旧 geojson，优先使用旧 geojson 确定局部刷新范围。
-- SELECT * FROM gis_refresh_electric_fence(
--     '2c95908e958f3b75019593551f520126',
--     '{"fence_id":"fence_id","action":"delete","geojson":{"type":"Polygon","coordinates":[[[113.1,34.1],[113.2,34.1],[113.2,34.2],[113.1,34.2],[113.1,34.1]]]}}'
-- );

-- 推荐对接方式：使用拆参函数，避免业务侧手写 refresh_json。
-- 新增围栏后：项目ID + 围栏ID + 新围栏 GeoJSON 文本。
-- SELECT * FROM gis_refresh_electric_fence_add(
--     '2c95908e958f3b75019593551f520126',
--     'fence_id',
--     '{"type":"Polygon","coordinates":[[[113.1,34.1],[113.2,34.1],[113.2,34.2],[113.1,34.2],[113.1,34.1]]]}'
-- );

-- 删除围栏后：项目ID + 围栏ID。
-- SELECT * FROM gis_refresh_electric_fence_delete(
--     '2c95908e958f3b75019593551f520126',
--     'fence_id'
-- );

-- 编辑围栏后：项目ID + 围栏ID + 旧围栏 GeoJSON 文本 + 新围栏 GeoJSON 文本。
-- SELECT * FROM gis_refresh_electric_fence_edit(
--     '2c95908e958f3b75019593551f520126',
--     'fence_id',
--     '{"type":"Polygon","coordinates":[[[113.1,34.1],[113.2,34.1],[113.2,34.2],[113.1,34.2],[113.1,34.1]]]}',
--     '{"type":"Polygon","coordinates":[[[113.1,34.1],[113.3,34.1],[113.3,34.3],[113.1,34.3],[113.1,34.1]]]}'
-- );

