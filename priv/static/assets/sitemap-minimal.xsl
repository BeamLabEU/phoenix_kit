<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="1.0"
  xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
  xmlns:sitemap="http://www.sitemaps.org/schemas/sitemap/0.9"
  exclude-result-prefixes="sitemap">

  <xsl:output method="html" indent="yes" encoding="UTF-8"/>

  <xsl:template match="/">
    <html>
      <head>
        <title>Sitemap</title>
        <style>
          body { font-family: system-ui, sans-serif; max-width: 800px; margin: 0 auto; padding: 2rem 1rem; background: #fff; color: #111; line-height: 1.5; }
          h1 { font-size: 1.25rem; font-weight: 600; margin-bottom: 0.5rem; }
          .count { color: #666; font-size: 14px; margin-bottom: 1.5rem; }
          ul { list-style: none; padding: 0; margin: 0; }
          li { padding: 8px 0; border-bottom: 1px solid #eee; }
          li:last-child { border-bottom: none; }
          a { color: #0066cc; text-decoration: none; word-break: break-all; }
          a:hover { text-decoration: underline; }
          footer { margin-top: 2rem; padding-top: 1rem; border-top: 1px solid #eee; font-size: 12px; color: #888; }
          @media (prefers-color-scheme: dark) {
            body { background: #111; color: #eee; }
            li { border-color: #333; }
            a { color: #66b3ff; }
            footer { border-color: #333; }
          }
        </style>
      </head>
      <body>
        <h1>Sitemap</h1>
        <p class="count"><xsl:value-of select="count(sitemap:urlset/sitemap:url)"/> URLs</p>
        <ul>
          <xsl:for-each select="sitemap:urlset/sitemap:url">
            <xsl:sort select="sitemap:loc"/>
            <li>
              <a href="{sitemap:loc}"><xsl:value-of select="sitemap:loc"/></a>
            </li>
          </xsl:for-each>
        </ul>
        <footer>PhoenixKit Sitemap</footer>
        <script>
          // Auto-reload on style change
          (function() {
            var currentStyle = 'minimal';
            var prefix = window.location.pathname.replace('/sitemap.xml', '');
            var checkUrl = prefix + '/sitemap/version';

            function checkVersion() {
              fetch(checkUrl, { cache: 'no-store' })
                .then(function(r) { return r.json(); })
                .then(function(data) {
                  if (data.style &amp;&amp; data.style !== currentStyle) {
                    window.location.reload();
                  }
                })
                .catch(function() {});
            }

            setInterval(checkVersion, 3000);
          })();
        </script>
      </body>
    </html>
  </xsl:template>

</xsl:stylesheet>
