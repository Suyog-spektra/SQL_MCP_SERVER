"""
FAQ SQL Assistant - MCP Server
-------------------------------
Exposes a single tool, `search_faq`, that a Microsoft Foundry Agent can call.
The tool connects to your Azure SQL Hyperscale database and runs the
dbo.SearchFAQ stored procedure (vector similarity search) to retrieve the
most relevant FAQ entries for a user's question.

Run with:
    python server.py

Then expose it publicly with devtunnel (see Exercise 4, Task 2), and point
Microsoft Foundry's MCP tool connector at the tunnel URL + /mcp.
"""

import os
import struct
import pyodbc
from dotenv import load_dotenv
from mcp.server.fastmcp import FastMCP

load_dotenv()

SQL_SERVER = os.environ["SQL_SERVER"]
SQL_DATABASE = os.environ["SQL_DATABASE"]
AUTH_MODE = os.environ.get("AUTH_MODE", "entra").lower()
SQL_USER = os.environ.get("SQL_USER", "")
SQL_PASSWORD = os.environ.get("SQL_PASSWORD", "")

# ODBC Driver 18 for SQL Server is the standard driver on Windows/macOS/Linux.
# If you have a different version installed, adjust this string accordingly
# (check with: python -c "import pyodbc; print(pyodbc.drivers())")
ODBC_DRIVER = "{ODBC Driver 18 for SQL Server}"

# SQL_COPT_SS_ACCESS_TOKEN -- the pyodbc/ODBC constant used to pass an Entra ID
# access token directly into the connection instead of a username/password.
SQL_COPT_SS_ACCESS_TOKEN = 1256


def get_connection():
    """Create a pyodbc connection using either SQL auth or Entra ID auth."""
    if AUTH_MODE == "sql":
        if not SQL_USER or not SQL_PASSWORD:
            raise RuntimeError("AUTH_MODE=sql requires SQL_USER and SQL_PASSWORD in .env")
        conn_str = (
            f"DRIVER={ODBC_DRIVER};"
            f"SERVER={SQL_SERVER};DATABASE={SQL_DATABASE};"
            f"UID={SQL_USER};PWD={SQL_PASSWORD};"
            f"Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;"
        )
        return pyodbc.connect(conn_str)

    elif AUTH_MODE == "entra":
        # Uses whatever Entra ID identity is available in this environment --
        # your own `az login` session, a managed identity, environment
        # variables, etc. (DefaultAzureCredential tries all of these in order).
        from azure.identity import DefaultAzureCredential

        credential = DefaultAzureCredential()
        token = credential.get_token("https://database.windows.net/.default")
        token_bytes = token.token.encode("utf-16-le")
        token_struct = struct.pack(f"<I{len(token_bytes)}s", len(token_bytes), token_bytes)

        conn_str = (
            f"DRIVER={ODBC_DRIVER};"
            f"SERVER={SQL_SERVER};DATABASE={SQL_DATABASE};"
            f"Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;"
        )
        return pyodbc.connect(conn_str, attrs_before={SQL_COPT_SS_ACCESS_TOKEN: token_struct})

    else:
        raise RuntimeError(f"Unknown AUTH_MODE: {AUTH_MODE!r} (expected 'sql' or 'entra')")


# ---------------------------------------------------------------------------
# MCP server + tool definition
# ---------------------------------------------------------------------------
mcp = FastMCP("FAQ SQL Assistant", host="0.0.0.0", port=8000)


@mcp.tool()
def search_faq(user_question: str) -> list[dict]:
    """
    Search the FAQ knowledge base for entries relevant to a customer question.

    Uses Azure SQL Hyperscale's native vector search (dbo.SearchFAQ stored
    procedure) to find the top 3 most semantically similar FAQ entries,
    regardless of exact keyword overlap.

    Args:
        user_question: The customer's support question, in natural language.

    Returns:
        A list of up to 3 FAQ matches, each with faq_id, category, question,
        and answer. Returns an empty list if no relevant FAQ is found.
    """
    conn = get_connection()
    try:
        cursor = conn.cursor()
        cursor.execute("EXEC dbo.SearchFAQ @user_question = ?", user_question)

        columns = [col[0] for col in cursor.description]
        rows = cursor.fetchall()

        results = [dict(zip(columns, row)) for row in rows]
        return results
    finally:
        conn.close()


if __name__ == "__main__":
    print("[MCP] Starting FAQ SQL Assistant on http://0.0.0.0:8000")
    print("[MCP] MCP endpoint : http://0.0.0.0:8000/mcp")
    mcp.run(transport="streamable-http")
