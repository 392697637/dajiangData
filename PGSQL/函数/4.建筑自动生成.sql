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
-- id 处理规则：
--   1. 如果目标表已有 id 字段，则保持原 id 不变。
--   2. 如果没有 id 但有 gid，则新增与 gid 相同类型的 id，并复制 gid 到 id。
--   3. 如果 id 和 gid 都不存在，则新增 SERIAL 自增 id。
-- ============================================================
DROP FUNCTION IF EXISTS public.gis_generate_building_3d(text);

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
    IF v_srid != 4326 THEN
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
    --    1. 底面：使用反向原始面，每个 Polygon 只生成一次，法线朝下。
    --    2. 顶面：把原始面沿 Z 方向抬升 height，每个 Polygon 只生成一次，法线朝上。
    --    3. 侧面：把每个面环拆成线段，每条线段只生成一个四边形墙面。
    --    4. 最终把底面、侧面和顶面合并为 MultiPolygonZ。
    EXECUTE format('
        UPDATE %I AS t
        SET geom3d = (
            WITH
            -- poly：把 MultiPolygon 拆成单个 Polygon，后续底面、顶面、侧面都以单个 Polygon 为单位生成，
            -- 避免 MultiPolygon 直接取环时出现重复面或环关系混乱。
            poly AS (
                SELECT (ST_Dump(t.geom)).geom AS geom
            ),
            -- rings：提取每个 Polygon 的所有环。
            -- ST_DumpRings 会返回外环和内洞环对应的 Polygon，ST_Boundary 再把环面转成闭合线。
            -- 后续侧面按闭合线的相邻点对生成。
            rings AS (
                SELECT
                    ST_Boundary((ST_DumpRings(poly.geom)).geom) AS geom,
                    COALESCE(t.height, 5) AS h
                FROM poly
            ),
            -- wall_faces：每条环边生成一个四边形墙面。
            -- 点序为：底边起点 -> 底边终点 -> 顶边终点 -> 顶边起点 -> 回到底边起点。
            -- generate_series 到 ST_NPoints - 1，是因为闭合线最后一个点等于第一个点，避免重复生成首尾边。
            wall_faces AS (
                SELECT
                    ST_SetSRID(
                        ST_MakePolygon(
                            ST_MakeLine(ARRAY[
                                ST_PointN(rings.geom, n),
                                ST_PointN(rings.geom, n + 1),
                                ST_Translate(ST_PointN(rings.geom, n + 1), 0, 0, rings.h),
                                ST_Translate(ST_PointN(rings.geom, n), 0, 0, rings.h),
                                ST_PointN(rings.geom, n)
                            ])
                        ),
                        4326
                    )::geometry(PolygonZ, 4326) AS geom
                FROM rings
                CROSS JOIN LATERAL generate_series(1, ST_NPoints(rings.geom) - 1) AS n
            ),
            -- bottom_faces：底面只按每个 Polygon 生成一次，并使用 ST_Reverse 反转点序，
            -- 让底面法线朝下，避免与顶面方向一致导致渲染时看起来像顶部双面。
            bottom_faces AS (
                SELECT
                    ST_Reverse(poly.geom)::geometry(PolygonZ, 4326) AS geom
                FROM poly
            ),
            -- top_faces：顶面只按每个 Polygon 生成一次，通过 Z 方向平移 height 得到。
            -- 不从 rings 生成顶面，避免外环/内洞环各自生成顶面造成重复。
            top_faces AS (
                SELECT
                    ST_Translate(poly.geom, 0, 0, COALESCE(t.height, 5))::geometry(PolygonZ, 4326) AS geom
                FROM poly
            ),
            -- all_faces：组合底面、侧面、顶面。
            -- 这里保留 UNION ALL，因为三类面来源互斥；使用 UNION 反而会增加排序/去重成本。
            all_faces AS (
                SELECT geom FROM bottom_faces
                UNION ALL
                SELECT geom FROM wall_faces
                UNION ALL
                SELECT geom FROM top_faces
            )
            -- ST_Collect 把所有面收集成 GeometryCollection，
            -- ST_CollectionExtract(..., 3) 只取 Polygon 面，
            -- ST_Multi 统一为 pg2b3dm 需要的 MultiPolygonZ。
            SELECT
                ST_Multi(ST_CollectionExtract(ST_Collect(geom), 3))::geometry(MultiPolygonZ, 4326) AS geom3d
            FROM all_faces
        )
        WHERE t.geom IS NOT NULL;
    ', v_table);
    GET DIAGNOSTICS v_row_count = ROW_COUNT;
    v_modified_count := v_modified_count + v_row_count;

    -- 7. 为 geom3d 创建 GIST 空间索引，加快后续空间查询和 3D Tiles 生成。
    EXECUTE format('
        CREATE INDEX IF NOT EXISTS idx_%I_geom3d ON %I USING GIST(geom3d);
    ', v_table, v_table);

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

COMMENT ON FUNCTION public.gis_generate_building_3d(text) IS
'根据项目ID处理建筑表 public.gis_buildings_项目ID：校验表存在，自动补齐 id 字段；如果 id 不存在但 gid 存在，则创建与 gid 相同类型的 id 并复制 gid 内容；如果 id 和 gid 都不存在，则创建 SERIAL 自增 id；随后处理 geom 的 SRID 和三维化；每次执行都会删除旧 geom3d 列并重新创建，再根据 height 生成包含底面、侧面和顶面的 MultiPolygonZ 建筑体块。底面反向生成使法线朝下，顶面按 Polygon 生成一次，侧面按边生成一次，避免顶部重复。返回 code、msg、modified_count，其中 modified_count 只统计 UPDATE 实际影响行数。';
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
DROP FUNCTION IF EXISTS public.gis_generate_3dtiles(TEXT);
DROP FUNCTION IF EXISTS public.exec_shell_cmd_capture(TEXT);


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


-- ============================================================
-- 函数：public.gis_generate_3dtiles(project_id TEXT)
-- 功能：根据项目 ID 自动生成建筑表对应的 3D Tiles。
-- 参数：
--   project_id  text  项目ID；实际建筑表名为 gis_buildings_项目ID
-- 返回：
--   code                integer  200成功，400参数错误，500执行异常
--   msg                 text     详细提示信息
--   file_relative_path  text     tileset.json 相对路径
--   file_absolute_path  text     tileset.json 绝对路径
-- ============================================================
CREATE FUNCTION public.gis_generate_3dtiles(project_id TEXT)
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

    -- 3. 检查建筑表是否存在，表名规则：public.gis_buildings_项目ID。
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

    -- 4. 新增 geom3d 列。
    -- 不修改原 geom 列，避免 geom 被视图依赖时报：
    -- cannot alter type of a column used by a view or rule
    IF NOT EXISTS (
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

    -- 5. 新增 height 列，默认高度 5。
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

    -- 6. 生成 geom3d。
    -- ST_Force3D：二维转三维；ST_Translate：按 height 抬升 Z；ST_Multi：转 MultiPolygon。
    EXECUTE format('
        UPDATE %I
        SET geom3d = ST_Multi(ST_Translate(ST_Force3D(geom), 0, 0, COALESCE(height, 5)))::geometry(MultiPolygonZ, 4326)
        WHERE geom IS NOT NULL
          AND (geom3d IS NULL OR ST_IsEmpty(geom3d));
    ', v_table);

    -- 7. 创建 geom3d 空间索引。
    IF to_regclass(format('public.%I', 'idx_' || v_table || '_geom3d')) IS NULL THEN
        EXECUTE format('
            CREATE INDEX %I ON %I USING GIST(geom3d);
        ', 'idx_' || v_table || '_geom3d', v_table);
    END IF;

    -- 8. 删除旧输出目录。
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

    -- 9. 确保父目录存在，并设置 755 权限。
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

    -- 10. 创建当前项目输出目录，并递归设置为 755。
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

    -- 11. 调用 pg2b3dm 生成 3D Tiles。
    -- -t 指定建筑表，-c 指定三维几何列 geom3d，-a 指定需要写入 b3dm batch table 的属性。
    -- 输出目录是当前项目目录，最终入口文件为 v_outdir/tileset.json。
    v_cmd := format(
        '/usr/local/bin/pg2b3dm '
        || '--connection %L '
        || '-t %I -c geom3d '
        || '-o %L '
        || '-a %L '
        || '--max_features_per_tile 30 '
        || '--default_color %L '
        || '--geometricerror 2000 '
        || '--subdivision QUADTREE '
        || '--add_outlines true',
        'Host=localhost;Port=5432;Database=ktd_lx_2026gis;Username=zhuoyi;Password=Ktd@postSQL@2026!@#;CommandTimeOut=3600',
        v_table,
        v_outdir,
        'id,height,age,quality,function',
        '#ffffff'
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
            '执行成功：3D Tiles 已生成',
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


-- 授权业务用户执行函数。
GRANT EXECUTE ON FUNCTION public.exec_shell_cmd_capture(TEXT) TO zhuoyi;
GRANT EXECUTE ON FUNCTION public.gis_generate_3dtiles(TEXT) TO zhuoyi;


-- ============================================================
-- 调用示例
-- ============================================================

-- 示例 1：生成项目 aaaaa 的 3D Tiles。
-- SELECT * FROM public.gis_generate_3dtiles('aaaaa');

-- 示例 2：生成指定项目的 3D Tiles。
-- SELECT * FROM public.gis_generate_3dtiles('bbbb');

-- 示例 3：测试 shell 命令执行函数。
-- SELECT * FROM public.exec_shell_cmd_capture('echo "hello"');

-- 示例 4：测试 PostgreSQL 服务进程用户是否能创建目标目录。 

-- SELECT * FROM public.exec_shell_cmd_capture('/bin/mkdir -p /home/postgres/ktd-pgdata/3dtiles/gis_buildings_aaaaa');

   
