// Runs at build time on Vercel (see package.json "build" script).
// Reads the PROJECT_REF / CLIENT_NAME / EST_COMPLETION environment variables
// (set in Vercel -> Project -> Settings -> Environment Variables) and writes
// them into env-config.js, which the dashboard loads to display those values.
// Locally, the checked-in env-config.js is used as-is (sensible defaults).
const fs = require('fs');

const projectRef = process.env.PROJECT_REF || 'PZ-0142';
const clientName = process.env.CLIENT_NAME || 'Aurora Retail Co.';
const estCompletion = process.env.EST_COMPLETION || '2026-09-05';
const startDate = process.env.START_DATE || '2026-07-30';

const content = `// Auto-generated at build time by build.js — do not edit directly.
window.PROVADA_CONFIG = {
  projectRef: ${JSON.stringify(projectRef)},
  clientName: ${JSON.stringify(clientName)},
  estCompletion: ${JSON.stringify(estCompletion)},
  startDate: ${JSON.stringify(startDate)}
};
`;

fs.writeFileSync('env-config.js', content);
console.log('Generated env-config.js:', { projectRef, clientName, estCompletion, startDate });
