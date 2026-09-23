#!/usr/bin/env node
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

async function main() {
  console.error('Connecting to Lightroom MCP server...');
  
  const transport = new StdioClientTransport({
    command: 'node',
    args: ['dist/index.js'],
    cwd: 'C:\\Users\\pablo\\mcp-servers\\mcp-lightroom\\pired-lightroom-mcp\\server'
  });

  const client = new Client({
    name: 'lightroom-metadata-client',
    version: '1.0.0'
  }, {
    capabilities: {}
  });

  await client.connect(transport);
  console.error('Connected!');

  // Initialize
  await client.initialize();
  console.error('Initialized!');

  // Get selected photos
  console.error('\n--- Getting selected photos ---');
  const selectedResult = await client.callTool({
    name: 'get_selected_photos',
    arguments: { limit: 10 }
  });
  console.error('Selected photos result:', JSON.stringify(selectedResult, null, 2));

  // Parse the result to get photo IDs
  let photoIds = [];
  try {
    const content = selectedResult.content;
    if (content && content[0] && content[0].text) {
      const parsed = JSON.parse(content[0].text);
      if (parsed.photos) {
        photoIds = parsed.photos.map(p => p.id || p.localIdentifier || p);
      }
    }
  } catch (e) {
    console.error('Error parsing selected photos:', e.message);
  }

  // If we have photos, get metadata for the first one
  if (photoIds.length > 0) {
    const photoId = photoIds[0];
    console.error(`\n--- Getting metadata for photo ${photoId} ---`);
    const metadataResult = await client.callTool({
      name: 'get_photo_metadata',
      arguments: { photo_id: photoId }
    });
    console.error('Metadata result:', JSON.stringify(metadataResult, null, 2));
  } else {
    console.error('No photos selected or found');
  }

  await client.close();
  process.exit(0);
}

main().catch(err => {
  console.error('Error:', err);
  process.exit(1);
});
