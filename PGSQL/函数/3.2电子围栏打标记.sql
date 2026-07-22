-- =============================================================================
-- 3.2电子围栏打标记.sql
 
--   gis_mark_electric_fence                 标记网格电子围栏障碍
--   gis_refresh_electric_fence              刷新网格电子围栏标记
--
-- =============================================================================
 
-- ============================================================ gis_refresh_electric_fence  重置所有网格====================================================================================
-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_refresh_electric_fence');

-- ==============================================
-- 函数名：gis_refresh_electric_fence
-- 功能描述：刷新三维网格的电子围栏标记。先清空已标记的zone_type，再重新标记。
-- 参数：p_project_id - 项目ID（可选，空表示公共表）
--       p_refresh_json - 可选刷新JSON；包含fence_id时只刷新该围栏影响范围。
-- 返回值：标准TABLE结构
--   code        integer     返回码：200成功，500执行异常
--   table_name  text        操作的网格表名
--   msg         text        结果描述
--   count       bigint      更新记录数
-- 适用场景：电子围栏数据修改后，快速刷新网格区域标记
-- 说明：
--   - 局部刷新会先找到指定围栏范围，再把该范围内所有可能重叠的有效围栏重新计算一遍；
--   - 如果围栏已经被物理删除且无法找到原 geom，无法确定影响范围，只能做全量刷新；
--   - 推荐业务删除围栏时使用软删除，然后调用本函数局部刷新。
-- ==============================================
-- =============================================================================
-- 函数介绍：gis_refresh_electric_fence
-- 主要作用：刷新网格中的电子围栏标记，可全量刷新，也可按单个围栏局部刷新。
-- 入参说明：p_project_id 为项目ID；p_refresh_json 为空或不含fence_id时全量刷新，包含fence_id时按围栏范围局部刷新。
-- 返回说明：返回清除和更新后的总影响行数，以及本次刷新状态信息。
-- 注意事项：局部刷新依赖围栏原始geom确定影响范围；删除围栏后建议保留软删除记录再刷新。
-- =============================================================================
CREATE OR REPLACE FUNCTION gis_refresh_electric_fence(
    p_project_id VARCHAR DEFAULT '',
    p_refresh_json jsonb DEFAULT NULL
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
    v_log_sql text;                 -- 当前函数调用SQL，用于错误日志
BEGIN
    v_fence_id := COALESCE(
        p_refresh_json ->> 'fence_id',
        p_refresh_json ->> 'fenceId',
        p_refresh_json ->> 'id'
    );
    v_is_partial := COALESCE(NULLIF(btrim(v_fence_id), ''), '') <> '';

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

    IF NOT v_is_partial THEN
        EXECUTE format('
            UPDATE %I
            SET
                zone_type = NULL,
                block_mask = COALESCE(block_mask, 0) & ~1,
                is_flyable = ((COALESCE(block_mask, 0) & ~1) = 0)
            WHERE zone_type IS NOT NULL
               OR (COALESCE(block_mask, 0) & 1) <> 0
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
        IF p_refresh_json IS NOT NULL THEN
            v_action := lower(COALESCE(
                p_refresh_json ->> 'action',
                p_refresh_json ->> 'operate',
                p_refresh_json ->> 'operation',
                p_refresh_json ->> 'type',
                ''
            ));
            v_fence_type := COALESCE(p_refresh_json ->> 'fence_type', p_refresh_json ->> 'fenceType');
            v_new_geojson := COALESCE(
                p_refresh_json -> 'geojson',
                p_refresh_json -> 'geom',
                p_refresh_json -> 'geometry',
                p_refresh_json -> 'new_geojson',
                p_refresh_json -> 'newGeom',
                p_refresh_json -> 'new_geometry'
            );
            v_old_geojson := COALESCE(
                p_refresh_json -> 'old_geojson',
                p_refresh_json -> 'oldGeom',
                p_refresh_json -> 'old_geometry'
            );

            IF v_action IN ('add', 'insert', 'create', '新增') THEN
                IF v_new_geojson IS NULL THEN
                    code := 400;
                    msg := format('参数错误：新增刷新必须提供geojson，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
                    count := 0;
                    INSERT INTO public.gis_error_log(code, msg, sqlstring)
                    VALUES (code, msg, v_log_sql);
                    RETURN NEXT;
                    RETURN;
                END IF;

                INSERT INTO tmp_refresh_scope_fence (geom4326)
                SELECT ST_SetSRID(ST_Force2D(ST_GeomFromGeoJSON(CASE WHEN v_new_geojson ->> 'type' = 'Feature' THEN v_new_geojson ->> 'geometry' ELSE v_new_geojson::text END)), 4326);

            ELSIF v_action IN ('edit', 'update', 'modify', '编辑') THEN
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
                    INSERT INTO tmp_refresh_scope_fence (geom4326)
                    SELECT ST_SetSRID(ST_Force2D(ST_GeomFromGeoJSON(CASE WHEN v_new_geojson ->> 'type' = 'Feature' THEN v_new_geojson ->> 'geometry' ELSE v_new_geojson::text END)), 4326);
                END IF;

                IF v_old_geojson IS NOT NULL THEN
                    INSERT INTO tmp_refresh_scope_fence (geom4326)
                    SELECT ST_SetSRID(ST_Force2D(ST_GeomFromGeoJSON(CASE WHEN v_old_geojson ->> 'type' = 'Feature' THEN v_old_geojson ->> 'geometry' ELSE v_old_geojson::text END)), 4326);
                END IF;

            ELSIF v_action IN ('delete', 'remove', 'del', '删除') THEN
                IF v_new_geojson IS NOT NULL THEN
                    INSERT INTO tmp_refresh_scope_fence (geom4326)
                    SELECT ST_SetSRID(ST_Force2D(ST_GeomFromGeoJSON(CASE WHEN v_new_geojson ->> 'type' = 'Feature' THEN v_new_geojson ->> 'geometry' ELSE v_new_geojson::text END)), 4326);
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

            IF v_fence_type IS NULL OR v_fence_type NOT IN ('1', '2', '3') THEN
                code := 400;
                msg := format('参数错误：fence_type必须是1/2/3，执行时间 %s 秒', ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
                count := 0;
                INSERT INTO public.gis_error_log(code, msg, sqlstring)
                VALUES (code, msg, v_log_sql);
                RETURN NEXT;
                RETURN;
            END IF;
        END IF;

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

    INSERT INTO tmp_refresh_electric_fence (
        id, source_table, priority, zone_type, max_height, geom4326
    )
    SELECT
        id::text,
        'bo_electric_fence',
        CASE fence_type WHEN '1' THEN 10 WHEN '2' THEN 20 WHEN '3' THEN 30 END AS priority,
        CASE fence_type
            WHEN '1' THEN '禁飞区'
            WHEN '2' THEN '管控区'
            WHEN '3' THEN '适飞区'
        END::varchar(20) AS zone_type,
        NULLIF(COALESCE(height, 0), 0)::double precision AS max_height,
        ST_SetSRID(ST_Force2D(geom), 4326) AS geom4326
    FROM bo_electric_fence
    WHERE del_flag = false
      AND status = '1'
      AND geom IS NOT NULL
      AND fence_type IN ('1', '2', '3')
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
                    NULL::double precision AS max_height,
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

    IF v_scope_extent IS NULL THEN
        EXECUTE format('
            UPDATE %I
            SET
                zone_type = NULL,
                block_mask = COALESCE(block_mask, 0) & ~1,
                is_flyable = ((COALESCE(block_mask, 0) & ~1) = 0)
            WHERE zone_type IS NOT NULL
               OR (COALESCE(block_mask, 0) & 1) <> 0
        ', v_table);
        GET DIAGNOSTICS v_cleared_rows = ROW_COUNT;
        count := v_cleared_rows;
        code := 200;
        msg := format('无有效电子围栏，已清空 %s 条标记，执行时间 %s 秒', v_cleared_rows, ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3));
        RETURN NEXT;
        RETURN;
    END IF;

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
                f.id AS fence_id
            FROM (
                SELECT x, y, geom2d
                FROM tmp_refresh_scope_xy
            ) n
            JOIN tmp_refresh_electric_fence f
              ON n.geom2d && f.geom4326
             AND ST_Intersects(n.geom2d, f.geom4326)
        )
        SELECT DISTINCT ON (n.id)
            n.id,
            xy.zone_type
        FROM %I n
        JOIN xy_match xy
          ON n.x = xy.x
         AND n.y = xy.y
        WHERE xy.max_height IS NULL
           OR n.alt <= xy.max_height
        ORDER BY n.id, xy.priority, xy.fence_id
    ', v_table);

    EXECUTE 'CREATE INDEX IF NOT EXISTS idx_tmp_desired_zone_id ON tmp_desired_zone(id);';
    EXECUTE 'ANALYZE tmp_desired_zone;';

    EXECUTE format(' 
        UPDATE %I n
        SET
            zone_type = t.zone_type,
            block_mask = CASE
                WHEN t.zone_type IN (''禁飞区'', ''管控区'') THEN COALESCE(n.block_mask, 0) | 1
                ELSE COALESCE(n.block_mask, 0) & ~1
            END,
            is_flyable = CASE
                WHEN t.zone_type IN (''禁飞区'', ''管控区'') THEN false
                ELSE ((COALESCE(n.block_mask, 0) & ~1) = 0)
            END
        FROM tmp_desired_zone t
        WHERE n.id = t.id
          AND (
              n.zone_type IS DISTINCT FROM t.zone_type
              OR n.block_mask IS DISTINCT FROM CASE
                    WHEN t.zone_type IN (''禁飞区'', ''管控区'') THEN COALESCE(n.block_mask, 0) | 1
                    ELSE COALESCE(n.block_mask, 0) & ~1
                 END
              OR n.is_flyable IS DISTINCT FROM CASE
                    WHEN t.zone_type IN (''禁飞区'', ''管控区'') THEN false
                    ELSE ((COALESCE(n.block_mask, 0) & ~1) = 0)
                 END
          )
    ', v_table);
    GET DIAGNOSTICS v_updated_match_rows = ROW_COUNT;

    EXECUTE format('
        UPDATE %I n
        SET
            zone_type = NULL,
            block_mask = COALESCE(n.block_mask, 0) & ~1,
            is_flyable = ((COALESCE(n.block_mask, 0) & ~1) = 0)
        WHERE (n.zone_type IS NOT NULL OR (COALESCE(n.block_mask, 0) & 1) <> 0)
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
COMMENT ON FUNCTION gis_refresh_electric_fence(VARCHAR, jsonb) IS '刷新网格电子围栏标记';
 


-- =============================================================================
-- 建筑障碍打标函数已拆分到 4.2建筑标记.sql
-- =============================================================================

-- =============================================================================
-- 函数调用示例
-- =============================================================================
-- SELECT * FROM gis_generate_3d_grid(
--     '2c95908e958f3b75019593551f520126',
--     '{"type":"Polygon","coordinates":[[[112.70,34.20],[114.20,34.20],[114.20,35.00],[112.70,35.00],[112.70,34.20]]]}',
--     0,
--     300,
--     100
-- );

-- SELECT * FROM gis_mark_electric_fence('2c95908e958f3b75019593551f520126');

-- 当围栏数据发生变更（如新增、修改、删除），调用此函数刷新全部区域标记。
-- SELECT * FROM gis_refresh_electric_fence('2c95908e958f3b75019593551f520126', NULL::jsonb);

-- 只刷新指定围栏影响范围。
-- SELECT * FROM gis_refresh_electric_fence('2c95908e958f3b75019593551f520126', '{"fence_id":"围栏ID"}'::jsonb);

-- 新增围栏后：用新geojson确定刷新范围
-- SELECT * FROM gis_refresh_electric_fence(
--     '2c95908e958f3b75019593551f520126',
--     '{"fence_id":"围栏ID","action":"add","fence_type":"1","geojson":{"type":"Polygon","coordinates":[[[113.1,34.1],[113.2,34.1],[113.2,34.2],[113.1,34.2],[113.1,34.1]]]}}'::jsonb
-- );

-- 编辑围栏后：用新geojson + old_geojson共同确定刷新范围；old_geojson不传时按围栏ID查询
-- SELECT * FROM gis_refresh_electric_fence(
--     '2c95908e958f3b75019593551f520126',
--     '{"fence_id":"围栏ID","action":"edit","fence_type":"2","geojson":{"type":"Polygon","coordinates":[[[113.1,34.1],[113.3,34.1],[113.3,34.3],[113.1,34.3],[113.1,34.1]]]},"old_geojson":{"type":"Polygon","coordinates":[[[113.1,34.1],[113.2,34.1],[113.2,34.2],[113.1,34.2],[113.1,34.1]]]}}'::jsonb
-- );

-- 删除围栏后：优先用geojson确定旧范围；geojson不传时按围栏ID查询
-- SELECT * FROM gis_refresh_electric_fence(
--     '2c95908e958f3b75019593551f520126',
--     '{"fence_id":"围栏ID","action":"delete","fence_type":"3","geojson":{"type":"Polygon","coordinates":[[[113.1,34.1],[113.2,34.1],[113.2,34.2],[113.1,34.2],[113.1,34.1]]]}}'::jsonb
-- );

