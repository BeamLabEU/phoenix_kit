<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="1.0"
  xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
  xmlns:sitemap="http://www.sitemaps.org/schemas/sitemap/0.9"
  exclude-result-prefixes="sitemap">

  <xsl:output method="html" indent="yes" encoding="UTF-8"/>

  <xsl:template match="/">
    <html>
      <head>
        <title>Sitemap Index</title>
        <style>
          body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 2rem; background: #f8fafc; color: #1e293b; }
          h1 { font-size: 1.5rem; margin-bottom: 0.5rem; }
          .info { color: #64748b; margin-bottom: 1.5rem; font-size: 14px; }
          ul { list-style: none; padding: 0; }
          li { padding: 6px 0; border-bottom: 1px solid #e2e8f0; }
          li:last-child { border-bottom: none; }
          a { color: #3b82f6; text-decoration: none; }
          a:hover { text-decoration: underline; }
          @media (prefers-color-scheme: dark) {
            body { background: #0f172a; color: #f1f5f9; }
            li { border-color: #334155; }
          }
        </style>
      </head>
      <body>
        <h1>Sitemap Index</h1>
        <p class="info">
          <xsl:value-of select="count(sitemap:sitemapindex/sitemap:sitemap)"/> sitemap files
        </p>
        <ul>
          <xsl:for-each select="sitemap:sitemapindex/sitemap:sitemap">
            <li>
              <a href="{sitemap:loc}"><xsl:value-of select="sitemap:loc"/></a>
            </li>
          </xsl:for-each>
        </ul>
      </body>
    </html>
  </xsl:template>

</xsl:stylesheet>
