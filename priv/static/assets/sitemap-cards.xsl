<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="1.0"
  xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
  xmlns:sitemap="http://www.sitemaps.org/schemas/sitemap/0.9"
  exclude-result-prefixes="sitemap">

  <xsl:output method="html" indent="yes" encoding="UTF-8"/>

  <xsl:template match="/">
    <html>
      <head>
        <title>Site Map</title>
        <style>
          body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 2rem; background: #f8fafc; color: #1e293b; }
          h1 { font-size: 2rem; text-align: center; margin-bottom: 0.5rem; }
          .subtitle { text-align: center; color: #64748b; margin-bottom: 2rem; }
          .stats { display: flex; justify-content: center; gap: 2rem; margin-bottom: 2rem; }
          .stat { background: white; padding: 1rem 1.5rem; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); text-align: center; }
          .stat-value { font-size: 1.5rem; font-weight: 700; color: #3b82f6; }
          .stat-label { font-size: 12px; color: #64748b; text-transform: uppercase; }
          .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 1.5rem; }
          .card { background: white; border-radius: 12px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); overflow: hidden; }
          .card-header { padding: 1rem 1.25rem; border-bottom: 1px solid #e2e8f0; display: flex; justify-content: space-between; align-items: center; }
          .card-title { font-weight: 600; }
          .card-count { background: #f1f5f9; padding: 4px 12px; border-radius: 999px; font-size: 12px; color: #64748b; }
          .url-list { list-style: none; padding: 0; margin: 0; max-height: 400px; overflow-y: auto; }
          .url-item { padding: 12px 1.25rem; border-bottom: 1px solid #e2e8f0; }
          .url-item:last-child { border-bottom: none; }
          .url-item:hover { background: #f8fafc; }
          a { color: #3b82f6; text-decoration: none; font-size: 14px; word-break: break-all; }
          a:hover { text-decoration: underline; }
          .meta { font-size: 12px; color: #94a3b8; margin-top: 4px; }
          @media (prefers-color-scheme: dark) {
            body { background: #0f172a; color: #f1f5f9; }
            .stat, .card { background: #1e293b; }
            .card-header, .url-item { border-color: #334155; }
            .url-item:hover { background: #334155; }
            .card-count { background: #334155; color: #94a3b8; }
          }
        </style>
      </head>
      <body>
        <h1>Site Map</h1>
        <p class="subtitle">Browse all pages on this website</p>
        <div class="stats">
          <div class="stat">
            <div class="stat-value"><xsl:value-of select="count(sitemap:urlset/sitemap:url)"/></div>
            <div class="stat-label">Total URLs</div>
          </div>
        </div>
        <div class="cards">
          <!-- Main pages (homepage) -->
          <xsl:variable name="main" select="sitemap:urlset/sitemap:url[
            string-length(substring-after(substring-after(sitemap:loc, '://'), '/')) &lt; 2
          ]"/>
          <xsl:if test="count($main) &gt; 0">
            <div class="card">
              <div class="card-header">
                <span class="card-title">Main</span>
                <span class="card-count"><xsl:value-of select="count($main)"/></span>
              </div>
              <ul class="url-list">
                <xsl:for-each select="$main">
                  <li class="url-item">
                    <a href="{sitemap:loc}"><xsl:value-of select="sitemap:loc"/></a>
                    <xsl:if test="sitemap:lastmod">
                      <div class="meta"><xsl:value-of select="sitemap:lastmod"/></div>
                    </xsl:if>
                  </li>
                </xsl:for-each>
              </ul>
            </div>
          </xsl:if>

          <!-- Content pages -->
          <xsl:variable name="content" select="sitemap:urlset/sitemap:url[
            string-length(substring-after(substring-after(sitemap:loc, '://'), '/')) &gt;= 2
          ]"/>
          <xsl:if test="count($content) &gt; 0">
            <div class="card">
              <div class="card-header">
                <span class="card-title">Content</span>
                <span class="card-count"><xsl:value-of select="count($content)"/></span>
              </div>
              <ul class="url-list">
                <xsl:for-each select="$content">
                  <xsl:sort select="sitemap:loc"/>
                  <li class="url-item">
                    <a href="{sitemap:loc}"><xsl:value-of select="sitemap:loc"/></a>
                    <xsl:if test="sitemap:lastmod">
                      <div class="meta"><xsl:value-of select="sitemap:lastmod"/></div>
                    </xsl:if>
                  </li>
                </xsl:for-each>
              </ul>
            </div>
          </xsl:if>
        </div>
        <p style="margin-top: 2rem; text-align: center; color: #94a3b8; font-size: 12px;">
          Generated by PhoenixKit
        </p>
      </body>
    </html>
  </xsl:template>

</xsl:stylesheet>
