Render every `.mmd` via  
npx @mermaid-js/mermaid-cli -i <file>.mmd -o ../img/<file>.svg  

CI script `scripts/verify_diagrams.sh` fails if the SVG is stale.
