"""数据库、鉴权等运行配置。

所有敏感项都优先从环境变量读取，未设置时使用本机演示环境的默认值。
正式部署时请至少覆盖 MYSQL_PASSWORD、PGVECTOR_PASSWORD 和 JWT_SECRET。
"""

import os

MYSQL_HOST = os.environ.get("MYSQL_HOST", "localhost")
MYSQL_PORT = int(os.environ.get("MYSQL_PORT", "3306"))
MYSQL_DATABASE = os.environ.get("MYSQL_DATABASE", "ai_rag")
MYSQL_USER = os.environ.get("MYSQL_USER", "root")
MYSQL_PASSWORD = os.environ.get("MYSQL_PASSWORD", "root")

PGVECTOR_HOST = os.environ.get("PGVECTOR_HOST", "localhost")
PGVECTOR_PORT = int(os.environ.get("PGVECTOR_PORT", "5432"))
PGVECTOR_DATABASE = os.environ.get("PGVECTOR_DATABASE", "ai_rag_vector")
PGVECTOR_USER = os.environ.get("PGVECTOR_USER", "postgres")
PGVECTOR_PASSWORD = os.environ.get("PGVECTOR_PASSWORD", "123456")
PGVECTOR_DIMENSION = int(os.environ.get("PGVECTOR_DIMENSION", "1024"))

# 业务库：MySQL，保存用户、知识库、对话、评测等全部结构化数据
TORTOISE_ORM = {
    "connections": {
        "default": {
            "engine": "tortoise.backends.mysql",
            "credentials": {
                "host": MYSQL_HOST,
                "port": MYSQL_PORT,
                "database": MYSQL_DATABASE,
                "user": MYSQL_USER,
                "password": MYSQL_PASSWORD,
                "minsize": 1,
                "maxsize": 10,
                "charset": "utf8mb4",
                "echo": os.environ.get("MYSQL_ECHO", "0") == "1",
            },
        },
    },
    "apps": {
        "models": {
            # 指向 models 包，Tortoise 会扫描包里导出的所有 Model 子类
            "models": ["models"],
            "default_connection": "default",
        }
    },
    # 关闭 use_tz，让 Tortoise 统一按 Asia/Shanghai 生成业务时间
    "use_tz": False,
    "timezone": "Asia/Shanghai",
}

# 向量库：PostgreSQL + PGVector，只保存知识片段的向量和检索用元数据
# 业务数据仍然在上面的 MySQL 里，两个库通过 knowledge_chunk.id 关联
PGVECTOR = {
    "host": PGVECTOR_HOST,
    "port": PGVECTOR_PORT,
    "database": PGVECTOR_DATABASE,
    "user": PGVECTOR_USER,
    "password": PGVECTOR_PASSWORD,
    # 必须与 ai_model_config 中启用的向量模型输出维度一致
    "dimension": PGVECTOR_DIMENSION,
}

# 正式部署请设置一个足够长的随机字符串，例如：
# $env:JWT_SECRET = "replace-with-a-long-random-secret"
JWT_SECRET = os.environ.get(
    "JWT_SECRET",
    "ai-rag-advanced-knowledge-platform-jwt-secret",
)
JWT_ALGORITHM = os.environ.get("JWT_ALGORITHM", "HS256")
JWT_EXPIRE_HOURS = int(os.environ.get("JWT_EXPIRE_HOURS", "24"))