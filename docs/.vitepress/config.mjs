import { defineConfig } from "vitepress";

export default defineConfig({
  title: "Auditr",
  description:
    "Long-term, classified Salesforce Setup Audit Trail intelligence and security monitoring framework.",
  base: "/Auditr/",
  cleanUrls: true,
  lastUpdated: true,

  head: [
    ["link", { rel: "icon", type: "image/svg+xml", href: "/Auditr/auditr-logo.svg" }],
    ["meta", { name: "theme-color", content: "#10b981" }],
    ["meta", { name: "og:type", content: "website" }],
    ["meta", { name: "og:site_name", content: "Auditr for Salesforce" }]
  ],

  themeConfig: {
    logo: "/auditr-logo.svg",
    siteTitle: "Auditr",
    nav: [
      {
        text: "Guide",
        link: "/getting-started",
        activeMatch:
          "/getting-started|/control-center-and-incident-mode|/audit-mode|/classification-and-retention|/architecture"
      },
      { text: "Audit Mode & Change Packaging", link: "/audit-mode" },
      { text: "Control Center & Incident Mode", link: "/control-center-and-incident-mode" },
      { text: "Rules & Retention", link: "/classification-and-retention" },
      { text: "Architecture", link: "/architecture" },
      {
        text: "v1.2.0",
        items: [
          {
            text: "Install v1.2.0-1 (04tg7000000dK8XAAU)",
            link: "https://login.salesforce.com/packaging/installPackage.apexp?p0=04tg7000000dK8XAAU"
          },
          {
            text: "Source Code",
            link: "https://github.com/nithesh1992/Auditr"
          }
        ]
      }
    ],

    sidebar: [
      {
        text: "Introduction",
        items: [
          { text: "Why Auditr?", link: "/" },
          { text: "Getting Started", link: "/getting-started" }
        ]
      },
      {
        text: "Security & Operations",
        items: [
          {
            text: "Audit Mode & Change Packaging",
            link: "/audit-mode"
          },
          {
            text: "Control Center & Incident Mode",
            link: "/control-center-and-incident-mode"
          },
          {
            text: "Classification Rules & Retention",
            link: "/classification-and-retention"
          }
        ]
      },
      {
        text: "Internals & Reference",
        items: [
          { text: "Architecture, Data Model & Limits", link: "/architecture" }
        ]
      }
    ],

    socialLinks: [
      { icon: "github", link: "https://github.com/nithesh1992/Auditr" }
    ],

    search: {
      provider: "local"
    },

    editLink: {
      pattern: "https://github.com/nithesh1992/Auditr/edit/main/docs/:path",
      text: "Edit this page on GitHub"
    },

    footer: {
      message: "Released under the MIT License.",
      copyright: "Built for Salesforce security teams, admins, and architects."
    }
  }
});
