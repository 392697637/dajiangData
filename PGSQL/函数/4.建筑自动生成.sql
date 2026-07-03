-- ============================================================
-- 函数：public.gis_generate_building_3d(p_project_id text)
-- 功能：
--   按项目 ID 处理建筑空间表 public.gis_buildings_项目ID。
--   主要完成建筑表主键字段补齐、geom 坐标系/三维化处理、建筑体块拉伸和空间索引创建。
-- 参数：
--   p_project_id text  项目 ID；实际处理表名为 public.gis_buildings_项目ID。
-- 返回：
--   code           integer  返回码：200成功，400参数错误，500执行异常。
--   msg            text     详细提示信息。
--   modified_count integer  修改条数，只统计函数中 UPDATE 实际影响的行数，不统计 ALTER TABLE 等 DDL。
-- 依赖：
--   PostGIS 扩展；目标表至少应包含 geom 字段，height 字段不存在时按默认高度 5 处理。
-- geom3d 处理规则：
--   每次执行都会删除旧 geom3d 列并重新创建，确保三维建筑体块按当前 geom/height 全量重算。
--   生成后会剔除空结果或只有 1 个 Polygon 的单面数据，避免不完整体块进入 3D Tiles。
-- id 处理规则：
--   1. 如果目标表已有 id 字段，则保持原 id 不变。
--   2. 如果没有 id 但有 gid，则新增与 gid 相同类型的 id，并复制 gid 到 id。
--   3. 如果 id 和 gid 都不存在，则新增 SERIAL 自增 id。
-- ============================================================
-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_generate_building_3d');

CREATE OR REPLACE FUNCTION public.gis_generate_building_3d(p_project_id text)
RETURNS TABLE (
    code           integer,  -- 返回码：200成功，400参数错误，500执行异常。
    msg            text,     -- 详细提示信息。
    modified_count integer   -- 修改条数：累计 UPDATE 实际影响的行数。
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_table          text := 'gis_buildings_' || p_project_id;  -- 当前项目对应的建筑表名。
    v_has_id         boolean;                                   -- 目标表是否已经存在 id 字段。
    v_has_gid        boolean;                                   -- 目标表是否存在 gid 字段。
    v_has_pk         boolean;                                   -- 目标表是否已经存在主键约束。
    v_gid_type       text;                                      -- gid 字段的完整类型，例如 integer、bigint、varchar(32)。
    v_srid           int;                                       -- geom 字段当前 SRID，用于判断是否需要投影转换。
    v_geom_type      text;                                      -- geom 字段当前 PostGIS 类型，用于避免重复 ALTER TYPE。
    v_row_count      integer := 0;                              -- 最近一条 UPDATE 影响的行数。
    v_modified_count integer := 0;                              -- 本次函数累计 UPDATE 实际影响行数。
    v_has_height     boolean;                                   -- 目标表是否存在 height 字段。
BEGIN
    -- 0. 参数校验：项目 ID 不能为空，且只能包含字母、数字、下划线。
    IF p_project_id IS NULL OR btrim(p_project_id) = '' THEN
        RETURN QUERY SELECT
            400,
            '参数错误：项目ID不能为空',
            0;
        RETURN;
    END IF;

    IF p_project_id !~ '^[a-zA-Z0-9_]+$' THEN
        RETURN QUERY SELECT
            400,
            '参数错误：项目ID只能包含字母、数字、下划线，当前值为 ' || p_project_id,
            0;
        RETURN;
    END IF;

    -- 1. 检查目标建筑表是否存在；不存在时直接抛出异常，避免后续动态 SQL 误操作。
    IF NOT EXISTS (SELECT 1 FROM pg_tables WHERE tablename = v_table AND schemaname = 'public') THEN
        RETURN QUERY SELECT
            400,
            format('参数错误：表 %s 不存在', v_table),
            0;
        RETURN;
    END IF;

    -- 2. 处理 id 列：
    --    已有 id 时保持不变；
    --    没有 id 但有 gid 时，创建同类型 id 并复制 gid 的值；
    --    id 和 gid 都不存在时，创建 SERIAL 自增 id。
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = v_table
          AND column_name = 'id'
    ) INTO v_has_id;

    IF NOT v_has_id THEN
        -- id 不存在时，先判断是否有 gid，决定 id 的来源。
        SELECT EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = 'public'
              AND table_name = v_table
              AND column_name = 'gid'
        ) INTO v_has_gid;

        IF v_has_gid THEN
            -- 读取 gid 的真实字段类型，保证新增 id 与 gid 类型一致，避免复制时发生类型转换错误。
            SELECT format_type(a.atttypid, a.atttypmod)
            INTO v_gid_type
            FROM pg_attribute a
            JOIN pg_class c ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'public'
              AND c.relname = v_table
              AND a.attname = 'gid'
              AND a.attnum > 0
              AND NOT a.attisdropped;

            -- 新增 id 字段，并把 gid 的现有值复制到 id。
            EXECUTE format('ALTER TABLE %I ADD COLUMN id %s', v_table, v_gid_type);
            EXECUTE format('UPDATE %I SET id = gid', v_table);
            GET DIAGNOSTICS v_row_count = ROW_COUNT;
            v_modified_count := v_modified_count + v_row_count;
        ELSE
            -- 没有 gid 可复制时，新增 SERIAL 字段，由 PostgreSQL 自动填充自增值。
            -- ADD COLUMN SERIAL 属于 DDL，不计入 modified_count；modified_count 只统计 UPDATE 行数。
            EXECUTE format('ALTER TABLE %I ADD COLUMN id SERIAL', v_table);
        END IF;

        -- 新增 id 后，如果表还没有主键，则把 id 设置为主键；
        -- 如果表已有其他主键，则给 id 加唯一约束，保证 pg2b3dm 属性 id 具备唯一性。
        SELECT EXISTS (
            SELECT 1 FROM information_schema.table_constraints
            WHERE table_schema = 'public'
              AND table_name = v_table
              AND constraint_type = 'PRIMARY KEY'
        ) INTO v_has_pk;

        IF NOT v_has_pk THEN
            EXECUTE format('ALTER TABLE %I ADD PRIMARY KEY (id)', v_table);
        ELSE
            EXECUTE format('ALTER TABLE %I ADD CONSTRAINT %I UNIQUE (id)',
                           v_table, v_table || '_id_key');
        END IF;
    END IF;

    -- 为 id 建普通索引，便于后续属性读取、唯一性检查和业务查询。
    IF to_regclass(format('public.%I', 'idx_' || v_table || '_id')) IS NULL THEN
        EXECUTE format('CREATE INDEX %I ON %I(id);', 'idx_' || v_table || '_id', v_table);
    END IF;

    -- 3. 获取当前 geom 列的 SRID，取第一条非空几何作为判断依据。
    EXECUTE format('SELECT ST_SRID(geom) FROM %I WHERE geom IS NOT NULL LIMIT 1', v_table) INTO v_srid;

    -- 若 SRID 为 0、-1 或 NULL，说明数据没有明确坐标系；
    -- 这里按历史处理规则假定为 EPSG:3857，并写回 geom 的 SRID。
    IF v_srid IS NULL OR v_srid IN (0, -1) THEN
        EXECUTE format('UPDATE %I SET geom = ST_SetSRID(geom, 3857) WHERE ST_SRID(geom) IN (0, -1) OR ST_SRID(geom) IS NULL', v_table);
        GET DIAGNOSTICS v_row_count = ROW_COUNT;
        v_modified_count := v_modified_count + v_row_count;
        v_srid := 3857;
    END IF;

    -- 4. 将 geom 转为 4326 坐标系，并强制补齐 Z 维度。
    -- ALTER COLUMN TYPE 属于 DDL，不计入 modified_count。
    SELECT type
    INTO v_geom_type
    FROM geometry_columns
    WHERE f_table_schema = 'public'
      AND f_table_name = v_table
      AND f_geometry_column = 'geom';

    IF v_srid = 4326 AND v_geom_type = 'MULTIPOLYGONZ' THEN
        -- 已经是目标类型时跳过 ALTER TABLE，避免 13 万数据重复全表重写。
        NULL;
    ELSIF v_srid != 4326 THEN
        -- 非 4326 数据先做 ST_Transform 投影转换，再通过 ST_Force3D 补 Z。
        EXECUTE format('
            ALTER TABLE %I
            ALTER COLUMN geom TYPE geometry(MultiPolygonZ, 4326)
            USING ST_Transform(ST_Force3D(geom), 4326);
        ', v_table);
    ELSE
        -- 已是 4326 时不再投影转换，只强制为三维 MultiPolygonZ。
        EXECUTE format('
            ALTER TABLE %I
            ALTER COLUMN geom TYPE geometry(MultiPolygonZ, 4326)
            USING ST_SetSRID(ST_Force3D(geom), 4326);
        ', v_table);
    END IF;

    -- 为 geom 建空间索引，提升 SRID 修正、空间范围读取和 pg2b3dm 前置查询效率。
    IF to_regclass(format('public.%I', 'idx_' || v_table || '_geom')) IS NULL THEN
        EXECUTE format('CREATE INDEX %I ON %I USING GIST(geom);', 'idx_' || v_table || '_geom', v_table);
    END IF;

    -- 5. 添加 height 列，并重建 geom3d 列；height 不存在时创建并使用默认高度 5。
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = v_table
          AND column_name = 'height'
    ) INTO v_has_height;

    IF NOT v_has_height THEN
        EXECUTE format('ALTER TABLE %I ADD COLUMN height NUMERIC DEFAULT 5', v_table);
    END IF;

    -- geom3d 用于保存真正的建筑体块面集合：底面 + 侧面 + 顶面。
    -- 每次执行都先删除旧 geom3d，再重新添加，确保高度、几何或生成逻辑变化后能全量重算。
    EXECUTE format('
        ALTER TABLE %I DROP COLUMN IF EXISTS geom3d;
        ALTER TABLE %I ADD COLUMN geom3d geometry(MultiPolygonZ, 4326);
    ', v_table, v_table);

    -- 删除 geom3d 后，旧的 geom3d 空间索引会随字段自动删除；
    -- 这里显式清理同名索引，避免历史异常残留影响后续 CREATE INDEX。
    IF to_regclass(format('public.%I', 'idx_' || v_table || '_geom3d')) IS NOT NULL THEN
        EXECUTE format('
            DROP INDEX %I;
        ', 'idx_' || v_table || '_geom3d');
    END IF;

    -- 6. 根据 height 拉伸生成建筑体块：
    --    1. 底面：使用反向规范面，每个 Polygon 只生成一次，法线朝下。
    --    2. 顶面：把规范面沿 Z 方向抬升 height，每个 Polygon 只生成一次，法线朝上。
    --    3. 侧面：把每个面环拆成线段，每条线段只生成一个四边形墙面。
    --    4. 最终把底面、侧面和顶面合并为 MultiPolygonZ。
    EXECUTE format('
        UPDATE %I AS t
        SET geom3d = (
            WITH
            input_poly AS (
                SELECT
                    ST_Force3D((ST_Dump(ST_CollectionExtract(ST_MakeValid(t.geom), 3))).geom)::geometry(PolygonZ, 4326) AS geom,
                    CASE
                        WHEN COALESCE(t.height, 5) > 0 THEN COALESCE(t.height, 5)
                        ELSE 5
                    END AS h
            ),
            -- 统一 Polygon 方向：外环逆时针、洞顺时针。这个方向作为顶面基准。
            poly AS (
                SELECT
                    ST_ForcePolygonCCW(ST_Force3D(geom))::geometry(PolygonZ, 4326) AS geom,
                    h
                FROM input_poly
                WHERE geom IS NOT NULL AND NOT ST_IsEmpty(geom)
            ),
            -- 底面：顶面基准方向反转，法线朝下。
            bottom_faces AS (
                SELECT
                    ST_Reverse(geom)::geometry(PolygonZ, 4326) AS geom
                FROM poly
            ),
            -- 顶面：沿 Z 方向抬升 height，法线朝上。
            top_faces AS (
                SELECT
                    ST_Translate(geom, 0, 0, h)::geometry(PolygonZ, 4326) AS geom
                FROM poly
            ),
            -- 提取外环和内洞环，后续每条环边生成一块侧墙。
            ring_lines AS (
                SELECT
                    ST_ExteriorRing(geom)::geometry(LineStringZ, 4326) AS geom,
                    h
                FROM poly
                UNION ALL
                SELECT
                    ST_InteriorRingN(poly.geom, ring_no)::geometry(LineStringZ, 4326) AS geom,
                    poly.h
                FROM poly
                CROSS JOIN LATERAL generate_series(1, ST_NumInteriorRings(poly.geom)) AS ring_no
            ),
            wall_segments AS (
                SELECT
                    geom,
                    h,
                    n
                FROM ring_lines
                CROSS JOIN LATERAL generate_series(1, ST_NPoints(geom) - 1) AS n
                WHERE ST_NPoints(geom) > 1
            ),
            -- 侧面：每条底边生成一个四边形墙面，包含底边、顶边和闭合点。
            wall_faces AS (
                SELECT
                    ST_MakePolygon(
                        ST_MakeLine(ARRAY[
                            ST_PointN(geom, n),
                            ST_PointN(geom, n + 1),
                            ST_Translate(ST_PointN(geom, n + 1), 0, 0, h),
                            ST_Translate(ST_PointN(geom, n), 0, 0, h),
                            ST_PointN(geom, n)
                        ])
                    )::geometry(PolygonZ, 4326) AS geom
                FROM wall_segments
            ),
            all_faces AS (
                SELECT geom FROM bottom_faces
                UNION ALL
                SELECT geom FROM wall_faces
                UNION ALL
                SELECT geom FROM top_faces
            )
            SELECT
                ST_Multi(ST_CollectionExtract(ST_Collect(geom), 3))::geometry(MultiPolygonZ, 4326) AS geom3d
            FROM all_faces
        )
        WHERE t.geom IS NOT NULL;
    ', v_table);
    GET DIAGNOSTICS v_row_count = ROW_COUNT;
    v_modified_count := v_modified_count + v_row_count;

    -- 7. 剔除生成后的单面数据。
    -- 正常建筑体块至少应包含底面、侧面、顶面等多个 Polygon；
    -- 如果 geom3d 为空或只有 1 个 Polygon，说明生成结果不是完整闭合体块，置空后避免进入 3D Tiles。
    EXECUTE format('
        UPDATE %I
        SET geom3d = NULL
        WHERE geom3d IS NOT NULL
          AND (ST_IsEmpty(geom3d) OR ST_NumGeometries(geom3d) <= 1);
    ', v_table);
    GET DIAGNOSTICS v_row_count = ROW_COUNT;
    v_modified_count := v_modified_count + v_row_count;

    -- 8. 为 geom3d 创建 GIST 空间索引，加快后续空间查询和 3D Tiles 生成。
    IF to_regclass(format('public.%I', 'idx_' || v_table || '_geom3d')) IS NULL THEN
        EXECUTE format('
            CREATE INDEX %I ON %I USING GIST(geom3d);
        ', 'idx_' || v_table || '_geom3d', v_table);
    END IF;

    -- 更新统计信息，帮助后续 pg2b3dm 选择更合适的查询计划。
    EXECUTE format('ANALYZE %I', v_table);

    -- 所有处理完成后返回统一结果。
    RETURN QUERY SELECT
        200,
        format('执行成功：建筑三维数据已生成，实际更新 %s 条', v_modified_count),
        v_modified_count;

-- 未预料 SQL 异常统一返回 500，便于调用方按 code 判断结果。
EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT
        500,
        '执行异常：' || SQLERRM || ' | 错误码：' || SQLSTATE,
        COALESCE(v_modified_count, 0);
END;
$$;

COMMENT ON FUNCTION public.gis_generate_building_3d(text) IS '生成建筑三维体块';
-- SELECT public.gis_generate_building_3d('aaaaa');

-- DROP TABLE IF EXISTS public.gis_buildings_bbbbb CASCADE;
--   SELECT public.gis_generate_building_3d('bbbb');
 

-- ============================================================
-- 建筑 3D Tiles 自动生成脚本
-- 返回结构统一为：
--   code                integer     返回码：200成功，400参数错误，500执行异常
--   msg                 text        详细提示信息
--   file_relative_path  text        tileset.json 相对路径
--   file_absolute_path  text        tileset.json 绝对路径
-- ============================================================

-- 主函数依赖 exec_shell_cmd_capture，先删除主函数，再删除辅助函数。
-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_generate_3dtiles');

-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('exec_shell_cmd_capture');


-- ============================================================
-- 函数：public.exec_shell_cmd_capture(cmd TEXT)
-- 功能：在数据库服务器上执行 shell 命令，并返回标准化 code/msg。
-- 参数：
--   cmd  text     shell 命令
-- 返回：
--   code integer  200成功，400参数错误，500执行异常
--   msg  text     命令输出或错误详情
-- ============================================================
CREATE FUNCTION public.exec_shell_cmd_capture(cmd TEXT)
RETURNS TABLE (
    code integer,   -- 返回码：200成功，400参数错误，500执行异常
    msg  text       -- 详细提示信息：命令输出或错误详情
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_program   text;     -- 实际交给 COPY FROM PROGRAM 执行的命令
    v_exit_code integer;  -- shell 命令原始退出码
    v_output    text;     -- shell 命令输出内容
BEGIN
    -- 参数校验：空命令直接返回 400。
    IF cmd IS NULL OR btrim(cmd) = '' THEN
        code := 400;
        msg := '参数错误：cmd不能为空';
        RETURN NEXT;
        RETURN;
    END IF;

    -- 创建会话级临时表，用来接收 COPY FROM PROGRAM 的输出。
    -- 先判断再创建，避免 CREATE TEMP TABLE IF NOT EXISTS 产生 NOTICE。
    IF to_regclass('pg_temp._cmd_result') IS NULL THEN
        CREATE TEMP TABLE _cmd_result (line text) ON COMMIT DROP;
    END IF;

    -- 每次执行前清空上一次命令输出。
    TRUNCATE _cmd_result;

    -- 组装实际执行命令：
    --   1. mktemp 创建临时文件保存 stdout/stderr。
    --   2. 设置 umask 022，确保新建文件默认不会是 600/700。
    --   3. 执行传入 cmd，并记录原始退出码。
    --   4. tr -d '\r' 清理 pg2b3dm 进度输出里的回车符。
    --   5. 输出 __EXIT_CODE 标记，供 PL/pgSQL 解析真实退出码。
    v_program :=
        'tmp=$(/bin/mktemp /tmp/pgcmd.XXXXXX); (umask 022; ' || cmd || E') >"$tmp" 2>&1; rc=$?; '
        || E'/usr/bin/tr -d ''\\r'' < "$tmp"; /bin/rm -f "$tmp"; '
        || E'printf ''\\n__EXIT_CODE:%s\\n'' "$rc"';

    -- COPY FROM PROGRAM 在数据库服务器执行命令，执行用户通常是 postgres。
    EXECUTE format('COPY _cmd_result(line) FROM PROGRAM %L', v_program);

    -- 解析 shell 原始退出码。
    SELECT COALESCE(replace(line, '__EXIT_CODE:', '')::integer, 1)
    INTO v_exit_code
    FROM _cmd_result
    WHERE line LIKE '__EXIT_CODE:%'
    ORDER BY ctid DESC
    LIMIT 1;

    -- 拼接命令普通输出，排除退出码标记行。
    SELECT NULLIF(string_agg(line, E'\n'), '')
    INTO v_output
    FROM _cmd_result
    WHERE line NOT LIKE '__EXIT_CODE:%';

    v_exit_code := COALESCE(v_exit_code, 1);
    v_output := COALESCE(v_output, '');

    -- 转换为业务统一返回码。
    IF v_exit_code = 0 THEN
        code := 200;
        msg := CASE
            WHEN v_output = '' THEN '命令执行成功'
            ELSE '命令执行成功：' || v_output
        END;
    ELSE
        code := 500;
        msg := format('命令执行失败，退出码 %s，详情：%s', v_exit_code, v_output);
    END IF;

    RETURN NEXT;

-- COPY FROM PROGRAM 或解析过程异常时，统一返回 500。
EXCEPTION WHEN OTHERS THEN
    code := 500;
    msg := '命令执行异常：' || SQLERRM || ' | 错误码：' || SQLSTATE;
    RETURN NEXT;
END;
$$;
COMMENT ON FUNCTION public.exec_shell_cmd_capture(TEXT) IS '执行命令并返回结果';


-- ============================================================
-- 函数：public.gis_generate_3dtiles(project_id TEXT, p_config_json TEXT DEFAULT NULL)
-- 功能：根据项目 ID 自动生成建筑表对应的 3D Tiles。
-- 参数：
--   project_id      text  项目ID；实际建筑表名为 gis_buildings_项目ID
--   p_config_json   text  JSON 字符串；可不传、传 NULL、传空字符串或传 jsonb_build_object()::text。
--                         所有 JSON 参数均可省略；省略时使用下面默认值，或不启用对应 pg2b3dm 可选参数。
--                         示例：SELECT * FROM public.gis_generate_3dtiles('bbbb');
--                         示例：SELECT * FROM public.gis_generate_3dtiles('bbbb', jsonb_build_object()::text);
--                         可包含以下参数：
--                         pg2b3dm_path text，默认 /usr/local/bin/pg2b3dm。
--                           作用：pg2b3dm 可执行文件路径。
--                           建议：工具安装路径变化时传入，例如 /opt/pg2b3dm/pg2b3dm。
--                         geom_column text，默认 geom3d。
--                           作用：传给 pg2b3dm 的 -c/--column，指定用于生成 3D Tiles 的几何列。
--                           建议：常规使用 geom3d；该列应为 geometry(MultiPolygonZ,4326) 或 pg2b3dm 支持的 3D 几何。
--                         output_dir text，默认 /home/postgres/ktd-pgdata/3dtiles/gis_buildings_项目ID。
--                           作用：传给 pg2b3dm 的 -o/--output，指定 3D Tiles 输出目录。
--                           建议：使用数据库服务用户可写、Web 服务可读的目录。
--                         worker integer，默认 4，范围 1-16。
--                           作用：设置 PostgreSQL 查询并行 worker 数；值越大，pg2b3dm 读取和空间计算阶段可用并行能力越高。
--                           建议：13 万级数据可用 8-12；机器 CPU 核数不足时不要设太高。
--                         max_features_tile integer，默认 300，范围 30-2000。
--                           作用：设置每个瓦片最大要素数；值越小瓦片越细、文件越多，值越大瓦片越少、单瓦片越重。
--                           建议：大数据量通常 300-500，比默认 30 更快。
--                         attributes text，默认 id,height,age,quality,function。
--                           作用：控制写入 3D Tiles batch table 的属性字段；字段越多，输出文件越大、生成越慢。
--                           建议：只保留前端需要展示/查询的字段，例如 id,height。
--                         close_outlines boolean，默认 false。
--                           作用：是否关闭轮廓线；true 时会把 pg2b3dm 的 --add_outlines 设置为 false。
--                           建议：大数据量或只看体块时设 true，可减少生成和渲染负担。
--                         add_outlines boolean，默认由 close_outlines 反向计算；如果传入，会直接作为 pg2b3dm --add_outlines 的值，并优先于 close_outlines。
--                           作用：控制是否生成轮廓线。
--                           建议：大数据量通常 false；需要边线效果时 true。
--                         geometricerror integer，默认 2000，范围 1-100000。
--                           作用：控制 3D Tiles 几何误差；值越大，通常瓦片层级越少，加载更快但细节切换更粗。
--                           建议：大范围建筑可适当增大，例如 3000-5000。
--                         geometricerrorfactor numeric，默认不传，范围 1-100。
--                           作用：传给 pg2b3dm --geometricerrorfactor，控制子层级几何误差衰减速度。
--                           建议：默认通常为 2；值越大层级误差下降越快，层级切换更激进。
--                         subdivision text，默认 QUADTREE，可选 QUADTREE/OCTREE。
--                           作用：控制空间切分方式；QUADTREE 适合常规平面城市建筑，OCTREE 更偏三维空间分布数据。
--                           建议：建筑面数据优先用 QUADTREE。
--                         default_color text，默认 #ffffff。
--                           作用：设置没有单独颜色属性时的默认颜色；支持 #RRGGBB 或 #AARRGGBB。
--                           建议：需要透明度时使用 #AARRGGBB，否则使用 #RRGGBB。
--                         default_metallic_roughness text，默认不传，格式 #RRGGBB 或 #AARRGGBB。
--                           作用：传给 pg2b3dm --default_metallic_roughness，控制默认金属度/粗糙度材质参数。
--                           建议：没有特殊材质需求时不传。
--                         double_sided boolean，默认不传。
--                           作用：控制材质是否双面渲染；true 能看到背面，但会增加渲染负担。
--                           建议：建筑体块闭合时用 false 或不传。
--                         refinement text，默认不传，可选 ADD/REPLACE。
--                           作用：控制父子瓦片细化策略；REPLACE 通常表示子瓦片加载后替换父瓦片。
--                           建议：常规 3D Tiles 建筑可用 REPLACE。
--                         use_implicit_tiling boolean，默认不传。
--                           作用：控制是否使用隐式瓦片；可减少 tileset.json 体积，但依赖 pg2b3dm 和前端支持。
--                           建议：确认前端支持后再开启。
--                         default_alpha_mode text，默认不传，可选 OPAQUE/BLEND/MASK。
--                           作用：控制默认透明模式；OPAQUE 不透明，BLEND 混合透明，MASK 镂空透明。
--                           建议：不需要透明时用 OPAQUE。
--                         alpha_cutoff numeric，默认不传，范围 0-1。
--                           作用：传给 pg2b3dm --alpha_cutoff；当 default_alpha_mode=MASK 时控制透明裁剪阈值。
--                           建议：只有 MASK 透明模式才需要传，常用 0.5。
--                         keep_projection boolean，默认不传。
--                           作用：控制是否保持原始投影。
--                           建议：输出常规 3D Tiles 时通常为 false。
--                         tileset_version text，默认 1.1。
--                           作用：传给 pg2b3dm --tileset_version，写入 tileset.json 的版本信息。
--                           建议：数据更新或发布版本管理时传入，例如 1.0.0。
--                         copyright text，默认不传。
--                           作用：传给 pg2b3dm --copyright，写入 glTF/tileset 版权信息。
--                           建议：生产数据需要版权或来源声明时传入。
--                         query text，默认不传，即不过滤数据。
--                           作用：传给 pg2b3dm -q/--query，附加过滤条件；pg2b3dm 会自行拼接 WHERE。
--                           建议：用于分区、分批生成，例如 geom3d IS NOT NULL 或 height > 10；
--                                 如果误写 WHERE 开头，函数会自动去掉。注意只传可信 SQL 条件。
--                         lod_column text，默认不传。
--                           作用：传给 pg2b3dm -l/--lodcolumn，指定 LOD 层级字段。
--                           建议：只有表中已有 LOD 字段时使用。
--                         radius_column text，默认不传。
--                           作用：传给 pg2b3dm --radiuscolumn，指定点云/点要素半径字段。
--                           建议：建筑面数据一般不需要。
--                         shaders_column text，默认不传。
--                           作用：传给 pg2b3dm --shaderscolumn，指定自定义 shader 字段。
--                           建议：高级自定义渲染时才使用。
--                         skip_create_tiles boolean，默认不传，由 pg2b3dm 使用自身默认值。
--                           作用：传给 pg2b3dm --skip_create_tiles，只生成/验证瓦片结构而跳过实际瓦片创建。
--                           建议：调试瓦片结构时使用，正式生成通常 false。
--                         connection text，不传则使用函数内默认连接。
--                           作用：pg2b3dm 连接数据库的连接字符串，例如 Host、Port、Database、Username、Password、CommandTimeOut。
--                           说明：如果 connection 中没有 Options，函数会自动追加 worker 对应的 PostgreSQL 并行参数。
-- 返回：
--   code                integer  200成功，400参数错误，500执行异常
--   msg                 text     详细提示信息
--   file_relative_path  text     tileset.json 相对路径
--   file_absolute_path  text     tileset.json 绝对路径
-- ============================================================
CREATE FUNCTION public.gis_generate_3dtiles(
    project_id TEXT,
    p_config_json TEXT DEFAULT NULL
)
RETURNS TABLE (
    code               integer,  -- 返回码：200成功，400参数错误，500执行异常
    msg                text,     -- 详细提示信息
    file_relative_path text,     -- 文件相对路径，例如 3dtiles/gis_buildings_xxx/tileset.json
    file_absolute_path text      -- 文件绝对路径，例如 /home/postgres/ktd-pgdata/3dtiles/gis_buildings_xxx/tileset.json
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_table              text := 'gis_buildings_' || project_id;                  -- 建筑表名
    v_outdir             text := '/home/postgres/ktd-pgdata/3dtiles/' || v_table;     -- 输出目录绝对路径
    v_file_relative_path text := '3dtiles/' || v_table || '/tileset.json';        -- tileset 相对路径
    v_file_absolute_path text := v_outdir || '/tileset.json';                     -- tileset 绝对路径
    v_cmd                text;                                                     -- 待执行 shell 命令
    v_rec                record;                                                   -- shell 执行结果
    v_pg2b3dm_path       text := '/usr/local/bin/pg2b3dm';                         -- pg2b3dm 可执行文件路径。
    v_geom_column        text := 'geom3d';                                         -- pg2b3dm 使用的几何列。
    v_parallel_workers   integer := 4;                                             -- 实际使用的并行 worker 数。
    v_max_features       integer := 300;                                           -- 实际使用的每瓦片最大要素数。
    v_attributes         text := 'id,height,age,quality,function';                 -- 输出到 batch table 的属性列。
    v_close_outlines     boolean := false;                                         -- 是否关闭轮廓线。
    v_add_outlines       text := 'true';                                           -- pg2b3dm --add_outlines 参数值。
    v_geometricerror     integer := 2000;                                          -- pg2b3dm 几何误差。
    v_subdivision        text := 'QUADTREE';                                       -- pg2b3dm 空间切分方式。
    v_default_color      text := '#ffffff';                                        -- pg2b3dm 默认颜色。
    v_geometricerrorfactor numeric;                                                -- pg2b3dm 几何误差因子。
    v_metallic_roughness text;                                                     -- pg2b3dm 默认金属度/粗糙度。
    v_double_sided       text;                                                     -- pg2b3dm 是否双面渲染。
    v_refinement         text;                                                     -- pg2b3dm 细化策略。
    v_use_implicit       text;                                                     -- pg2b3dm 是否使用隐式瓦片。
    v_alpha_mode         text;                                                     -- pg2b3dm Alpha 模式。
    v_alpha_cutoff       numeric;                                                  -- pg2b3dm Alpha 裁剪阈值。
    v_keep_projection    text;                                                     -- pg2b3dm 是否保持原始投影。
    v_tileset_version    text := '1.1';                                            -- pg2b3dm tileset 版本。
    v_copyright          text;                                                     -- pg2b3dm 版权信息。
    v_query              text;                                                     -- pg2b3dm 查询过滤条件。
    v_lod_column         text;                                                     -- pg2b3dm LOD 字段。
    v_radius_column      text;                                                     -- pg2b3dm 半径字段。
    v_shaders_column     text;                                                     -- pg2b3dm shader 字段。
    v_skip_create_tiles  text;                                                     -- pg2b3dm 是否跳过创建瓦片。
    v_optional_args      text := '';                                               -- 可选 pg2b3dm 参数片段。
    v_config             jsonb := '{}'::jsonb;                                     -- JSON 配置对象。
    v_connection_base    text := 'Host=localhost;Port=5432;Database=ktd_lx_2026gis;Username=zhuoyi;Password=Ktd@postSQL@2026!@#;CommandTimeOut=3600'; -- pg2b3dm 基础数据库连接字符串。
    v_connection_options text;                                                     -- 追加到 pg2b3dm 连接串的 PostgreSQL Options 参数。
    v_connection         text;                                                     -- pg2b3dm 数据库连接字符串。
BEGIN
    -- 1. 参数校验：project_id 不能为空。
    IF project_id IS NULL OR btrim(project_id) = '' THEN
        RETURN QUERY SELECT
            400,
            '参数错误：项目ID不能为空',
            ''::text,
            ''::text;
        RETURN;
    END IF;

    -- 2. 参数校验：只允许字母、数字、下划线，避免动态 SQL 和 shell 注入。
    IF project_id !~ '^[a-zA-Z0-9_]+$' THEN
        RETURN QUERY SELECT
            400,
            '参数错误：项目ID只能包含字母、数字、下划线，当前值为 ' || project_id,
            ''::text,
            ''::text;
        RETURN;
    END IF;

    -- 3. 解析 JSON 配置。
    IF p_config_json IS NOT NULL AND btrim(p_config_json) <> '' THEN
        BEGIN
            v_config := p_config_json::jsonb;
        EXCEPTION WHEN OTHERS THEN
            RETURN QUERY SELECT
                400,
                '参数错误：p_config_json 不是合法 JSON 字符串：' || SQLERRM,
                ''::text,
                ''::text;
            RETURN;
        END;
    END IF;

    -- 4. pg2b3dm 基础参数校验。
    IF v_config ? 'pg2b3dm_path' THEN
        v_pg2b3dm_path := btrim(v_config ->> 'pg2b3dm_path');
    END IF;

    IF v_pg2b3dm_path IS NULL OR v_pg2b3dm_path = '' THEN
        RETURN QUERY SELECT
            400,
            '参数错误：pg2b3dm_path 不能为空',
            ''::text,
            ''::text;
        RETURN;
    END IF;

    IF v_pg2b3dm_path !~ '^/[A-Za-z0-9_./-]+$' THEN
        RETURN QUERY SELECT
            400,
            '参数错误：pg2b3dm_path 必须是绝对路径，且只能包含字母、数字、下划线、点、斜杠和短横线，当前值为 ' || v_pg2b3dm_path,
            ''::text,
            ''::text;
        RETURN;
    END IF;

    IF v_config ? 'geom_column' THEN
        v_geom_column := btrim(v_config ->> 'geom_column');
    END IF;

    IF v_geom_column IS NULL OR v_geom_column = '' THEN
        RETURN QUERY SELECT
            400,
            '参数错误：geom_column 不能为空',
            ''::text,
            ''::text;
        RETURN;
    END IF;

    IF v_geom_column !~ '^[a-zA-Z_][a-zA-Z0-9_]*$' THEN
        RETURN QUERY SELECT
            400,
            '参数错误：geom_column 只能是合法字段名，当前值为 ' || v_geom_column,
            ''::text,
            ''::text;
        RETURN;
    END IF;

    IF v_config ? 'output_dir' THEN
        v_outdir := btrim(v_config ->> 'output_dir');
        v_file_absolute_path := rtrim(v_outdir, '/') || '/tileset.json';
        v_file_relative_path := regexp_replace(v_file_absolute_path, '^/home/postgres/ktd-pgdata/', '');
    END IF;

    IF v_outdir IS NULL OR v_outdir = '' THEN
        RETURN QUERY SELECT
            400,
            '参数错误：output_dir 不能为空',
            ''::text,
            ''::text;
        RETURN;
    END IF;

    IF v_outdir !~ '^/[A-Za-z0-9_./-]+$' THEN
        RETURN QUERY SELECT
            400,
            '参数错误：output_dir 必须是绝对路径，且只能包含字母、数字、下划线、点、斜杠和短横线，当前值为 ' || v_outdir,
            ''::text,
            ''::text;
        RETURN;
    END IF;

    v_outdir := rtrim(v_outdir, '/');
    v_file_absolute_path := v_outdir || '/tileset.json';

    -- 5. 并行参数校验。
    -- pg2b3dm 自身没有独立线程参数；这里通过 PostgreSQL 查询并行参数加速其读取/空间计算阶段。
    IF v_config ? 'worker' THEN
        BEGIN
            v_parallel_workers := (v_config ->> 'worker')::integer;
        EXCEPTION WHEN OTHERS THEN
            RETURN QUERY SELECT
                400,
                '参数错误：worker 必须是整数',
                ''::text,
                ''::text;
            RETURN;
        END;
    END IF;

    IF v_parallel_workers < 1 OR v_parallel_workers > 16 THEN
        RETURN QUERY SELECT
            400,
            '参数错误：worker 取值范围为 1 到 16，当前值为 ' || v_parallel_workers,
            ''::text,
            ''::text;
        RETURN;
    END IF;

    -- 6. 瓦片要素数参数校验。
    -- 13 万级数据如果仍使用 30，会生成大量小瓦片和文件，通常会明显拖慢生成。
    IF v_config ? 'max_features_tile' THEN
        BEGIN
            v_max_features := (v_config ->> 'max_features_tile')::integer;
        EXCEPTION WHEN OTHERS THEN
            RETURN QUERY SELECT
                400,
                '参数错误：max_features_tile 必须是整数',
                ''::text,
                ''::text;
            RETURN;
        END;
    END IF;

    IF v_max_features < 30 OR v_max_features > 2000 THEN
        RETURN QUERY SELECT
            400,
            '参数错误：max_features_tile 取值范围为 30 到 2000，当前值为 ' || v_max_features,
            ''::text,
            ''::text;
        RETURN;
    END IF;

    -- 7. 输出属性列和轮廓线参数。
    IF v_config ? 'attributes' THEN
        v_attributes := btrim(v_config ->> 'attributes');
    END IF;

    IF v_attributes IS NULL OR v_attributes = '' THEN
        v_attributes := 'id,height';
    END IF;

    IF v_attributes !~ '^[a-zA-Z0-9_,]+$' THEN
        RETURN QUERY SELECT
            400,
            '参数错误：attributes 只能包含字母、数字、下划线和英文逗号，当前值为 ' || v_attributes,
            ''::text,
            ''::text;
        RETURN;
    END IF;

    IF v_config ? 'close_outlines' THEN
        BEGIN
            v_close_outlines := (v_config ->> 'close_outlines')::boolean;
        EXCEPTION WHEN OTHERS THEN
            RETURN QUERY SELECT
                400,
                '参数错误：close_outlines 必须是 true 或 false',
                ''::text,
                ''::text;
            RETURN;
        END;
    END IF;

    IF v_config ? 'add_outlines' THEN
        BEGIN
            v_add_outlines := ((v_config ->> 'add_outlines')::boolean)::text;
        EXCEPTION WHEN OTHERS THEN
            RETURN QUERY SELECT
                400,
                '参数错误：add_outlines 必须是 true 或 false',
                ''::text,
                ''::text;
            RETURN;
        END;
    ELSE
        v_add_outlines := CASE WHEN v_close_outlines THEN 'false' ELSE 'true' END;
    END IF;

    -- 8. pg2b3dm 其他可调参数。
    IF v_config ? 'geometricerror' THEN
        BEGIN
            v_geometricerror := (v_config ->> 'geometricerror')::integer;
        EXCEPTION WHEN OTHERS THEN
            RETURN QUERY SELECT
                400,
                '参数错误：geometricerror 必须是整数',
                ''::text,
                ''::text;
            RETURN;
        END;
    END IF;

    IF v_geometricerror < 1 OR v_geometricerror > 100000 THEN
        RETURN QUERY SELECT
            400,
            '参数错误：geometricerror 取值范围为 1 到 100000，当前值为 ' || v_geometricerror,
            ''::text,
            ''::text;
        RETURN;
    END IF;

    IF v_config ? 'geometricerrorfactor' THEN
        BEGIN
            v_geometricerrorfactor := (v_config ->> 'geometricerrorfactor')::numeric;
        EXCEPTION WHEN OTHERS THEN
            RETURN QUERY SELECT
                400,
                '参数错误：geometricerrorfactor 必须是数字',
                ''::text,
                ''::text;
            RETURN;
        END;
        IF v_geometricerrorfactor < 1 OR v_geometricerrorfactor > 100 THEN
            RETURN QUERY SELECT
                400,
                '参数错误：geometricerrorfactor 取值范围为 1 到 100，当前值为 ' || v_geometricerrorfactor,
                ''::text,
                ''::text;
            RETURN;
        END IF;
    END IF;
    IF v_geometricerrorfactor IS NOT NULL THEN
        IF v_geometricerrorfactor < 1 OR v_geometricerrorfactor > 100 THEN
            RETURN QUERY SELECT
                400,
                '参数错误：geometricerrorfactor 取值范围为 1 到 100，当前值为 ' || v_geometricerrorfactor,
                ''::text,
                ''::text;
            RETURN;
        END IF;
        v_optional_args := v_optional_args || format(' --geometricerrorfactor %s', v_geometricerrorfactor);
    END IF;

    IF v_config ? 'subdivision' THEN
        v_subdivision := upper(btrim(v_config ->> 'subdivision'));
    END IF;
    IF v_subdivision NOT IN ('QUADTREE', 'OCTREE') THEN
        RETURN QUERY SELECT
            400,
            '参数错误：subdivision 只能是 QUADTREE 或 OCTREE，当前值为 ' || v_subdivision,
            ''::text,
            ''::text;
        RETURN;
    END IF;

    IF v_config ? 'default_color' THEN
        v_default_color := btrim(v_config ->> 'default_color');
    END IF;
    IF v_default_color !~ '^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$' THEN
        RETURN QUERY SELECT
            400,
            '参数错误：default_color 必须是 #RRGGBB 或 #AARRGGBB，当前值为 ' || v_default_color,
            ''::text,
            ''::text;
        RETURN;
    END IF;

    IF v_config ? 'default_metallic_roughness' THEN
        v_metallic_roughness := btrim(v_config ->> 'default_metallic_roughness');
        IF v_metallic_roughness !~ '^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$' THEN
            RETURN QUERY SELECT
                400,
                '参数错误：default_metallic_roughness 必须是 #RRGGBB 或 #AARRGGBB，当前值为 ' || v_metallic_roughness,
                ''::text,
                ''::text;
            RETURN;
        END IF;
        v_optional_args := v_optional_args || format(' --default_metallic_roughness %L', v_metallic_roughness);
    END IF;

    IF v_config ? 'double_sided' THEN
        BEGIN
            v_double_sided := ((v_config ->> 'double_sided')::boolean)::text;
        EXCEPTION WHEN OTHERS THEN
            RETURN QUERY SELECT
                400,
                '参数错误：double_sided 必须是 true 或 false',
                ''::text,
                ''::text;
            RETURN;
        END;
    END IF;
    IF v_double_sided IS NOT NULL THEN
        v_optional_args := v_optional_args || format(' --double_sided %s', v_double_sided);
    END IF;

    IF v_config ? 'refinement' THEN
        v_refinement := upper(btrim(v_config ->> 'refinement'));
        IF v_refinement NOT IN ('ADD', 'REPLACE') THEN
            RETURN QUERY SELECT
                400,
                '参数错误：refinement 只能是 ADD 或 REPLACE，当前值为 ' || v_refinement,
                ''::text,
                ''::text;
            RETURN;
        END IF;
    END IF;
    IF v_refinement IS NOT NULL THEN
        IF v_refinement NOT IN ('ADD', 'REPLACE') THEN
            RETURN QUERY SELECT
                400,
                '参数错误：refinement 只能是 ADD 或 REPLACE，当前值为 ' || v_refinement,
                ''::text,
                ''::text;
            RETURN;
        END IF;
        v_optional_args := v_optional_args || format(' --refinement %s', v_refinement);
    END IF;

    IF v_config ? 'use_implicit_tiling' THEN
        BEGIN
            v_use_implicit := ((v_config ->> 'use_implicit_tiling')::boolean)::text;
        EXCEPTION WHEN OTHERS THEN
            RETURN QUERY SELECT
                400,
                '参数错误：use_implicit_tiling 必须是 true 或 false',
                ''::text,
                ''::text;
            RETURN;
        END;
    END IF;
    IF v_use_implicit IS NOT NULL THEN
        v_optional_args := v_optional_args || format(' --use_implicit_tiling %s', v_use_implicit);
    END IF;

    IF v_config ? 'default_alpha_mode' THEN
        v_alpha_mode := upper(btrim(v_config ->> 'default_alpha_mode'));
        IF v_alpha_mode NOT IN ('OPAQUE', 'BLEND', 'MASK') THEN
            RETURN QUERY SELECT
                400,
                '参数错误：default_alpha_mode 只能是 OPAQUE、BLEND 或 MASK，当前值为 ' || v_alpha_mode,
                ''::text,
                ''::text;
            RETURN;
        END IF;
    END IF;
    IF v_alpha_mode IS NOT NULL THEN
        IF v_alpha_mode NOT IN ('OPAQUE', 'BLEND', 'MASK') THEN
            RETURN QUERY SELECT
                400,
                '参数错误：default_alpha_mode 只能是 OPAQUE、BLEND 或 MASK，当前值为 ' || v_alpha_mode,
                ''::text,
                ''::text;
            RETURN;
        END IF;
        v_optional_args := v_optional_args || format(' --default_alpha_mode %s', v_alpha_mode);
    END IF;

    IF v_config ? 'alpha_cutoff' THEN
        BEGIN
            v_alpha_cutoff := (v_config ->> 'alpha_cutoff')::numeric;
        EXCEPTION WHEN OTHERS THEN
            RETURN QUERY SELECT
                400,
                '参数错误：alpha_cutoff 必须是数字',
                ''::text,
                ''::text;
            RETURN;
        END;
        IF v_alpha_cutoff < 0 OR v_alpha_cutoff > 1 THEN
            RETURN QUERY SELECT
                400,
                '参数错误：alpha_cutoff 取值范围为 0 到 1，当前值为 ' || v_alpha_cutoff,
                ''::text,
                ''::text;
            RETURN;
        END IF;
        v_optional_args := v_optional_args || format(' --alpha_cutoff %s', v_alpha_cutoff);
    END IF;

    IF v_config ? 'keep_projection' THEN
        BEGIN
            v_keep_projection := ((v_config ->> 'keep_projection')::boolean)::text;
        EXCEPTION WHEN OTHERS THEN
            RETURN QUERY SELECT
                400,
                '参数错误：keep_projection 必须是 true 或 false',
                ''::text,
                ''::text;
            RETURN;
        END;
    END IF;
    IF v_keep_projection IS NOT NULL THEN
        v_optional_args := v_optional_args || format(' --keep_projection %s', v_keep_projection);
    END IF;

    IF v_config ? 'tileset_version' THEN
        v_tileset_version := btrim(v_config ->> 'tileset_version');
    END IF;
    IF v_tileset_version IS NULL OR v_tileset_version = '' OR v_tileset_version ~ '[\r\n]' THEN
        RETURN QUERY SELECT
            400,
            '参数错误：tileset_version 不能为空且不能包含换行符',
            ''::text,
            ''::text;
        RETURN;
    END IF;
    v_optional_args := v_optional_args || format(' --tileset_version %L', v_tileset_version);

    IF v_config ? 'copyright' THEN
        v_copyright := btrim(v_config ->> 'copyright');
        IF v_copyright IS NULL OR v_copyright = '' OR v_copyright ~ '[\r\n]' THEN
            RETURN QUERY SELECT
                400,
                '参数错误：copyright 不能为空且不能包含换行符',
                ''::text,
                ''::text;
            RETURN;
        END IF;
        v_optional_args := v_optional_args || format(' --copyright %L', v_copyright);
    END IF;

    IF v_config ? 'query' THEN
        v_query := btrim(v_config ->> 'query');
        IF v_query IS NULL OR v_query = '' OR v_query ~ '[\r\n;]' THEN
            RETURN QUERY SELECT
                400,
                '参数错误：query 不能为空，且不能包含换行符或分号',
                ''::text,
                ''::text;
            RETURN;
        END IF;

        -- pg2b3dm 的 -q 参数接收 WHERE 后面的条件表达式；
        -- 如果传入 WHERE 开头，pg2b3dm 内部再次拼接 WHERE 会导致语法错误。
        v_query := regexp_replace(v_query, '^[[:space:]]*WHERE[[:space:]]+', '', 'i');
        v_query := btrim(v_query);
        IF v_query = '' THEN
            RETURN QUERY SELECT
                400,
                '参数错误：query 去掉 WHERE 后不能为空，例如 geom3d IS NOT NULL',
                ''::text,
                ''::text;
            RETURN;
        END IF;
        v_optional_args := v_optional_args || format(' -q %L', v_query);
    END IF;

    IF v_config ? 'lod_column' THEN
        v_lod_column := btrim(v_config ->> 'lod_column');
        IF v_lod_column !~ '^[a-zA-Z_][a-zA-Z0-9_]*$' THEN
            RETURN QUERY SELECT
                400,
                '参数错误：lod_column 只能是合法字段名，当前值为 ' || v_lod_column,
                ''::text,
                ''::text;
            RETURN;
        END IF;
        v_optional_args := v_optional_args || format(' -l %I', v_lod_column);
    END IF;

    IF v_config ? 'radius_column' THEN
        v_radius_column := btrim(v_config ->> 'radius_column');
        IF v_radius_column !~ '^[a-zA-Z_][a-zA-Z0-9_]*$' THEN
            RETURN QUERY SELECT
                400,
                '参数错误：radius_column 只能是合法字段名，当前值为 ' || v_radius_column,
                ''::text,
                ''::text;
            RETURN;
        END IF;
        v_optional_args := v_optional_args || format(' --radiuscolumn %I', v_radius_column);
    END IF;

    IF v_config ? 'shaders_column' THEN
        v_shaders_column := btrim(v_config ->> 'shaders_column');
        IF v_shaders_column !~ '^[a-zA-Z_][a-zA-Z0-9_]*$' THEN
            RETURN QUERY SELECT
                400,
                '参数错误：shaders_column 只能是合法字段名，当前值为 ' || v_shaders_column,
                ''::text,
                ''::text;
            RETURN;
        END IF;
        v_optional_args := v_optional_args || format(' --shaderscolumn %I', v_shaders_column);
    END IF;

    IF v_config ? 'skip_create_tiles' THEN
        BEGIN
            v_skip_create_tiles := ((v_config ->> 'skip_create_tiles')::boolean)::text;
        EXCEPTION WHEN OTHERS THEN
            RETURN QUERY SELECT
                400,
                '参数错误：skip_create_tiles 必须是 true 或 false',
                ''::text,
                ''::text;
            RETURN;
        END;
        v_optional_args := v_optional_args || format(' --skip_create_tiles %s', v_skip_create_tiles);
    END IF;

    -- 9. 数据库连接参数。
    -- connection 直接传给 pg2b3dm --connection；命令拼接时会使用 %L 做 shell 字面量转义。
    IF v_config ? 'connection' THEN
        v_connection_base := btrim(v_config ->> 'connection');
    END IF;

    IF v_connection_base IS NULL OR v_connection_base = '' THEN
        RETURN QUERY SELECT
            400,
            '参数错误：connection 不能为空',
            ''::text,
            ''::text;
        RETURN;
    END IF;

    IF v_connection_base ~ '[\r\n]' THEN
        RETURN QUERY SELECT
            400,
            '参数错误：connection 不能包含换行符',
            ''::text,
            ''::text;
        RETURN;
    END IF;

    -- 10. 为当前数据库会话设置并行查询参数。
    -- 这对本函数内查询有效；pg2b3dm 会通过连接串 Options 再设置一遍。
    PERFORM set_config('max_parallel_workers_per_gather', v_parallel_workers::text, true);
    PERFORM set_config('parallel_setup_cost', '0', true);
    PERFORM set_config('parallel_tuple_cost', '0', true);
    PERFORM set_config('min_parallel_table_scan_size', '0', true);
    PERFORM set_config('min_parallel_index_scan_size', '0', true);

    -- 11. 检查建筑表是否存在，表名规则：public.gis_buildings_项目ID。
    IF NOT EXISTS (
        SELECT 1
        FROM pg_tables
        WHERE schemaname = 'public'
          AND tablename = v_table
    ) THEN
        RETURN QUERY SELECT
            400,
            format('参数错误：表 %s 不存在', v_table),
            v_file_relative_path,
            v_file_absolute_path;
        RETURN;
    END IF;

    -- 检查 pg2b3dm 输入几何列是否存在，避免命令执行到 pg2b3dm 后才报错。
    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = v_table
          AND column_name = v_geom_column
    ) AND v_geom_column <> 'geom3d' THEN
        RETURN QUERY SELECT
            400,
            format('参数错误：几何列 %s 不存在', v_geom_column),
            v_file_relative_path,
            v_file_absolute_path;
        RETURN;
    END IF;

    IF v_lod_column IS NOT NULL AND NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = v_table
          AND column_name = v_lod_column
    ) THEN
        RETURN QUERY SELECT
            400,
            format('参数错误：LOD 字段 %s 不存在', v_lod_column),
            v_file_relative_path,
            v_file_absolute_path;
        RETURN;
    END IF;

    IF v_radius_column IS NOT NULL AND NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = v_table
          AND column_name = v_radius_column
    ) THEN
        RETURN QUERY SELECT
            400,
            format('参数错误：半径字段 %s 不存在', v_radius_column),
            v_file_relative_path,
            v_file_absolute_path;
        RETURN;
    END IF;

    IF v_shaders_column IS NOT NULL AND NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = v_table
          AND column_name = v_shaders_column
    ) THEN
        RETURN QUERY SELECT
            400,
            format('参数错误：shader 字段 %s 不存在', v_shaders_column),
            v_file_relative_path,
            v_file_absolute_path;
        RETURN;
    END IF;

    -- 12. 新增 geom3d 列。
    -- 不修改原 geom 列，避免 geom 被视图依赖时报：
    -- cannot alter type of a column used by a view or rule
    IF v_geom_column = 'geom3d' AND NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = v_table
          AND column_name = 'geom3d'
    ) THEN
        EXECUTE format('
            ALTER TABLE %I ADD COLUMN geom3d geometry(MultiPolygonZ, 4326);
        ', v_table);
    END IF;

    -- 13. 新增 height 列，默认高度 5。
    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = v_table
          AND column_name = 'height'
    ) THEN
        EXECUTE format('
            ALTER TABLE %I ADD COLUMN height NUMERIC DEFAULT 5;
        ', v_table);
    END IF;

    -- 14. 生成 geom3d。
    -- ST_Force3D：二维转三维；ST_Translate：按 height 抬升 Z；ST_Multi：转 MultiPolygon。
    IF v_geom_column = 'geom3d' THEN
        EXECUTE format('
            UPDATE %I
            SET geom3d = ST_Multi(ST_Translate(ST_Force3D(geom), 0, 0, COALESCE(height, 5)))::geometry(MultiPolygonZ, 4326)
            WHERE geom IS NOT NULL
              AND (geom3d IS NULL OR ST_IsEmpty(geom3d));
        ', v_table);
    END IF;

    -- 15. 创建输入几何列空间索引。
    IF to_regclass(format('public.%I', 'idx_' || v_table || '_' || v_geom_column)) IS NULL THEN
        EXECUTE format('
            CREATE INDEX %I ON %I USING GIST(%I);
        ', 'idx_' || v_table || '_' || v_geom_column, v_table, v_geom_column);
    END IF;

    -- 16. 更新表统计信息，帮助 pg2b3dm 查询规划器选择更合适的执行计划。
    EXECUTE format('ANALYZE %I', v_table);

    -- 17. 删除旧输出目录。
    -- 注意：v_outdir 由固定根目录和已校验的 project_id 拼接而成，避免 shell 注入风险。
    v_cmd := '/bin/rm -rf ' || v_outdir;
    SELECT * INTO v_rec FROM exec_shell_cmd_capture(v_cmd);
    IF v_rec.code != 200 THEN
        RETURN QUERY SELECT
            500,
            '删除旧目录失败：' || v_rec.msg,
            v_file_relative_path,
            v_file_absolute_path;
        RETURN;
    END IF;

    -- 18. 确保父目录存在，并设置 755 权限。
    -- /usr/bin/id 和 ls -ld 会输出当前数据库服务进程用户及目录状态，便于排查权限问题。
    v_cmd := '/usr/bin/id; /bin/ls -ld /home/postgres/ktd-pgdata 2>/dev/null; /bin/mkdir -p /home/postgres/ktd-pgdata/3dtiles; /bin/chmod 755 /home/postgres/ktd-pgdata /home/postgres/ktd-pgdata/3dtiles';
    SELECT * INTO v_rec FROM exec_shell_cmd_capture(v_cmd);
    IF v_rec.code != 200 THEN
        RETURN QUERY SELECT
            500,
            '创建父目录 /home/postgres/ktd-pgdata/3dtiles 或设置权限失败：' || v_rec.msg,
            v_file_relative_path,
            v_file_absolute_path;
        RETURN;
    END IF;

    -- 19. 创建当前项目输出目录，并递归设置为 755。
    -- 使用 find -exec chmod，而不是只 chmod -R，是为了显式覆盖目录下每个文件/目录，
    -- 防止 pg2b3dm 或系统 umask 生成 700/600 权限后前端服务无法读取。
    v_cmd := format('/bin/mkdir -p %L; /usr/bin/find %L -exec /bin/chmod 755 {} \;', v_outdir, v_outdir);
    SELECT * INTO v_rec FROM exec_shell_cmd_capture(v_cmd);
    IF v_rec.code != 200 THEN
        RETURN QUERY SELECT
            500,
            format('创建目录 %s 或设置权限失败：%s', v_outdir, v_rec.msg),
            v_file_relative_path,
            v_file_absolute_path;
        RETURN;
    END IF;

    -- 20. 调用 pg2b3dm 生成 3D Tiles。
    -- -t 指定建筑表，-c 指定三维几何列，-a 指定需要写入 b3dm batch table 的属性。
    -- 输出目录是当前项目目录，最终入口文件为 v_outdir/tileset.json。
    -- Options 会把 PostgreSQL 并行查询参数传入 pg2b3dm 使用的新连接。
    v_connection_options := format(
        'Options=-c max_parallel_workers_per_gather=%s -c parallel_setup_cost=0 -c parallel_tuple_cost=0 -c min_parallel_table_scan_size=0 -c min_parallel_index_scan_size=0',
        v_parallel_workers
    );

    IF v_connection_base ~* '(^|;)Options=' THEN
        -- 调用方已经在 connection 中提供 Options 时，保持调用方配置，避免连接串里出现重复 Options。
        v_connection := v_connection_base;
    ELSE
        v_connection := rtrim(v_connection_base, ';') || ';' || v_connection_options;
    END IF;

    v_cmd := format(
        '%s '
        || '--connection %L '
        || '-t %I -c %I '
        || '-o %L '
        || '-a %L '
        || '--max_features_per_tile %s '
        || '--default_color %L '
        || '--geometricerror %s '
        || '--subdivision %s '
        || '--add_outlines %s'
        || '%s',
        v_pg2b3dm_path,
        v_connection,
        v_table,
        v_geom_column,
        v_outdir,
        v_attributes,
        v_max_features,
        v_default_color,
        v_geometricerror,
        v_subdivision,
        v_add_outlines,
        v_optional_args
    );

    SELECT * INTO v_rec FROM exec_shell_cmd_capture(v_cmd);
    IF v_rec.code = 200 THEN
        -- pg2b3dm 生成文件后，再统一修正输出目录及目录下所有文件权限为 755。
        -- 这一步必须放在 pg2b3dm 之后，因为真正的 tileset.json 和 b3dm 文件是在这里才生成。
        v_cmd := format('/usr/bin/find %L -exec /bin/chmod 755 {} \;', v_outdir);
        SELECT * INTO v_rec FROM exec_shell_cmd_capture(v_cmd);
        IF v_rec.code != 200 THEN
            RETURN QUERY SELECT
                500,
                '3D Tiles 已生成，但设置输出文件权限失败：' || v_rec.msg,
                v_file_relative_path,
                v_file_absolute_path;
            RETURN;
        END IF;

        RETURN QUERY SELECT
            200,
            format('执行成功：3D Tiles 已生成，worker=%s，max_features_tile=%s，attributes=%s，add_outlines=%s，geometricerror=%s，subdivision=%s，tileset_version=%s', v_parallel_workers, v_max_features, v_attributes, v_add_outlines, v_geometricerror, v_subdivision, v_tileset_version),
            v_file_relative_path,
            v_file_absolute_path;
    ELSE
        RETURN QUERY SELECT
            500,
            'pg2b3dm 执行失败：' || v_rec.msg,
            v_file_relative_path,
            v_file_absolute_path;
    END IF;

-- 未预料 SQL 异常统一返回 500。
EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT
        500,
        '执行异常：' || SQLERRM || ' | 错误码：' || SQLSTATE,
        COALESCE(v_file_relative_path, ''),
        COALESCE(v_file_absolute_path, '');
END;
$$;
COMMENT ON FUNCTION public.gis_generate_3dtiles(TEXT, TEXT) IS '生成建筑三维瓦片文件';


-- 授权业务用户执行函数。
GRANT EXECUTE ON FUNCTION public.exec_shell_cmd_capture(TEXT) TO zhuoyi;
GRANT EXECUTE ON FUNCTION public.gis_generate_3dtiles(TEXT, TEXT) TO zhuoyi;


-- ============================================================
-- 调用示例
-- ============================================================

-- 示例 1：生成项目 aaaaa 的 3D Tiles。
-- SELECT * FROM public.gis_generate_3dtiles('aaaaa');

-- 示例 2：13 万级数据推荐：worker=12，每瓦片最大要素数=500，只输出必要属性，关闭轮廓线。
-- SELECT * FROM public.gis_generate_3dtiles(
--     'bbbb',
--     '{"pg2b3dm_path":"/usr/local/bin/pg2b3dm","geom_column":"geom3d","worker":12,"max_features_tile":500,"attributes":"id,height","add_outlines":false,"geometricerror":3000,"geometricerrorfactor":2,"subdivision":"QUADTREE","default_color":"#ffffff","default_alpha_mode":"OPAQUE","keep_projection":false,"tileset_version":"1.1","connection":"Host=localhost;Port=5432;Database=ktd_lx_2026gis;Username=zhuoyi;Password=Ktd@postSQL@2026!@#;CommandTimeOut=3600"}'
-- );

-- 示例 2.1：带注释的完整 JSON 调用示例。
-- 注意：JSON 本身不能写注释，所以下面用 jsonb_build_object 组织参数；
-- 函数接收 text，因此最后通过 ::text 转成 JSON 字符串。
-- SELECT
--     *
-- FROM
--     public.gis_generate_3dtiles(
--         'bbbb',                                            -- 项目 ID，对应表 public.gis_buildings_bbbb。
--         jsonb_build_object(
--             'pg2b3dm_path', '/usr/local/bin/pg2b3dm',       -- pg2b3dm 可执行文件路径。
--             'geom_column', 'geom3d',                       -- 输入几何列，对应 pg2b3dm -c/--column。
--             'output_dir', '/home/postgres/ktd-pgdata/3dtiles/gis_buildings_bbbb',
--                                                            -- 输出目录，对应 pg2b3dm -o/--output。
--             'worker', 12,                                  -- PostgreSQL 并行 worker 数，范围 1-16。
--             'max_features_tile', 500,                      -- 每个瓦片最大要素数，13 万级数据建议 300-500。
--             'attributes', 'id,height',                     -- 输出到 3D Tiles batch table 的属性列，越少越快。
--             'add_outlines', false,                         -- 是否生成轮廓线；大数据量 false 通常更快。
--             'geometricerror', 3000,                        -- 几何误差，值越大瓦片层级通常越少。
--             'geometricerrorfactor', 2,                     -- 几何误差因子，控制子层级误差衰减速度。
--             'subdivision', 'QUADTREE',                     -- 空间切分方式，可选 QUADTREE/OCTREE。
--             'default_color', '#ffffff',                    -- 默认颜色，格式 #RRGGBB 或 #AARRGGBB。
--             'default_metallic_roughness', '#008000',       -- 默认金属度/粗糙度材质参数，不需要可删除。
--             'double_sided', false,                         -- 是否双面渲染，不需要时 false 可减少渲染负担。
--             'refinement', 'REPLACE',                       -- 瓦片细化策略，可选 ADD/REPLACE。
--             'use_implicit_tiling', false,                  -- 是否使用隐式瓦片，不需要可删除。
--             'default_alpha_mode', 'OPAQUE',                -- Alpha 模式，可选 OPAQUE/BLEND/MASK。
--             'alpha_cutoff', 0.5,                           -- Alpha 裁剪阈值，仅 MASK 透明模式通常需要。
--             'keep_projection', false,                      -- 是否保持原始投影，通常输出 3D Tiles 用 false。
--             'tileset_version', '1.1',                      -- tileset 版本，默认 1.1。
--             'copyright', 'ktd_lx_2026gis',                 -- 版权或数据来源声明。
--             'query', 'geom3d IS NOT NULL',                 -- 数据过滤条件，对应 pg2b3dm -q/--query；不要写 WHERE，写了也会自动去掉。
--             'skip_create_tiles', false,                    -- 是否跳过创建瓦片，调试时可设 true。
--             'connection', 'Host=localhost;Port=5432;Database=ktd_lx_2026gis;Username=zhuoyi;Password=Ktd@postSQL@2026!@#;CommandTimeOut=3600'
--                                                            -- pg2b3dm 数据库连接串；未包含 Options 时函数会自动追加并行参数。
--         )::text
--     );

-- 示例 3：测试 shell 命令执行函数。
-- SELECT * FROM public.exec_shell_cmd_capture('echo "hello"');

-- 示例 4：测试 PostgreSQL 服务进程用户是否能创建目标目录。 

-- SELECT * FROM public.exec_shell_cmd_capture('/bin/mkdir -p /home/postgres/ktd-pgdata/3dtiles/gis_buildings_aaaaa');

   
