-- ============================================================
-- 函数：public.gis_generate_building_3d(p_project_id text)
-- 功能：
--   按项目 ID 处理建筑空间表 public.gis_buildings_项目ID。
--   主要完成建筑表主键字段补齐、geom 坐标系/三维化处理、geom3d 生成和空间索引创建。
-- 参数：
--   p_project_id text  项目 ID；实际处理表名为 public.gis_buildings_项目ID。
-- 返回：
--   code           integer  返回码：200成功，400参数错误，500执行异常。
--   msg            text     详细提示信息。
--   modified_count integer  修改条数，统计函数中 UPDATE 影响的总行数。
-- 依赖：
--   PostGIS 扩展；目标表至少应包含 geom 字段，height 字段不存在时按默认高度 5 处理。
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
    modified_count integer   -- 修改条数：累计 UPDATE 影响的行数。
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
    v_table_count    integer := 0;                              -- 当前建筑表总行数，用于统计 DDL 自动补值影响的行数。
    v_modified_count integer := 0;                              -- 本次函数累计修改条数。
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

    -- 记录表总行数；ADD COLUMN SERIAL 和 ALTER COLUMN TYPE 这类 DDL 不会产生 ROW_COUNT，
    -- 但会对已有记录补值或重写几何字段，因此用表行数辅助累计修改条数。
    EXECUTE format('SELECT count(*) FROM %I', v_table) INTO v_table_count;

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
            EXECUTE format('ALTER TABLE %I ADD COLUMN id SERIAL', v_table);
            v_modified_count := v_modified_count + v_table_count;
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
    IF v_srid != 4326 THEN
        -- 非 4326 数据先做 ST_Transform 投影转换，再通过 ST_Force3D 补 Z。
        EXECUTE format('
            ALTER TABLE %I
            ALTER COLUMN geom TYPE geometry(MultiPolygonZ, 4326)
            USING ST_Transform(ST_Force3D(geom), 4326);
        ', v_table);
        v_modified_count := v_modified_count + v_table_count;
    ELSE
        -- 已是 4326 时不再投影转换，只强制为三维 MultiPolygonZ。
        EXECUTE format('
            ALTER TABLE %I
            ALTER COLUMN geom TYPE geometry(MultiPolygonZ, 4326)
            USING ST_SetSRID(ST_Force3D(geom), 4326);
        ', v_table);
        v_modified_count := v_modified_count + v_table_count;
    END IF;

    -- 5. 添加 geom3d 列，用于保存建筑三维几何；字段存在时保持原结构。
    EXECUTE format('
        ALTER TABLE %I
        ADD COLUMN IF NOT EXISTS geom3d geometry(MultiPolygonZ, 4326);
    ', v_table);

    -- 6. 根据 height 生成 geom3d；height 为空时按 5 作为默认高度。
    -- 注意：此处沿用原逻辑做 Z 方向偏移，不改动 XY 坐标。
    EXECUTE format('
        UPDATE %I
        SET geom3d = ST_Translate(geom, 0, 0, COALESCE(height, 5));
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
        format('执行成功：建筑三维数据已生成，累计修改 %s 条', v_modified_count),
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
'根据项目ID处理建筑表 public.gis_buildings_项目ID ';
-- SELECT public.gis_generate_building_3d('aaaaa');

-- DROP TABLE IF EXISTS public.gis_buildings_bbbbb CASCADE;
  SELECT public.gis_generate_building_3d('bbbb');
 

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
    --   2. 执行传入 cmd，并记录原始退出码。
    --   3. tr -d '\r' 清理 pg2b3dm 进度输出里的回车符。
    --   4. 输出 __EXIT_CODE 标记，供 PL/pgSQL 解析真实退出码。
    v_program :=
        'tmp=$(/bin/mktemp /tmp/pgcmd.XXXXXX); (' || cmd || E') >"$tmp" 2>&1; rc=$?; '
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
    file_absolute_path text      -- 文件绝对路径，例如 /home/postgres/pgdata/3dtiles/gis_buildings_xxx/tileset.json
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

    -- 9. 确保父目录存在。
    v_cmd := '/usr/bin/id; /bin/ls -ld /home/postgres/pgdata 2>/dev/null; /bin/mkdir -p /home/postgres/pgdata/3dtiles';
    SELECT * INTO v_rec FROM exec_shell_cmd_capture(v_cmd);
    IF v_rec.code != 200 THEN
        RETURN QUERY SELECT
            500,
            '创建父目录 /home/postgres/pgdata/3dtiles 失败：' || v_rec.msg,
            v_file_relative_path,
            v_file_absolute_path;
        RETURN;
    END IF;

    -- 10. 创建当前项目输出目录。
    v_cmd := format('/bin/mkdir -p %L', v_outdir);
    SELECT * INTO v_rec FROM exec_shell_cmd_capture(v_cmd);
    IF v_rec.code != 200 THEN
        RETURN QUERY SELECT
            500,
            format('创建目录 %s 失败：%s', v_outdir, v_rec.msg),
            v_file_relative_path,
            v_file_absolute_path;
        RETURN;
    END IF;

    -- 11. 调用 pg2b3dm 生成 3D Tiles。
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
SELECT * FROM public.gis_generate_3dtiles('aaaaa');

-- 示例 2：生成指定项目的 3D Tiles。
SELECT * FROM public.gis_generate_3dtiles('bbbb');

-- 示例 3：测试 shell 命令执行函数。
SELECT * FROM public.exec_shell_cmd_capture('echo "hello"');

-- 示例 4：测试 PostgreSQL 服务进程用户是否能创建目标目录。 

SELECT * FROM public.exec_shell_cmd_capture('/bin/mkdir -p /home/postgres/ktd-pgdata/3dtiles/gis_buildings_aaaaa');

   
