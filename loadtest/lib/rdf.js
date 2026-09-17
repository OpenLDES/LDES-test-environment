/**
 * Turtle serialisation helpers.
 *
 * The RDF datatype of every literal decides what `Ldio:LdioRdbOut` binds to the sink column:
 * its ValueConverter maps `xsd:dateTime` onto an OffsetDateTime and everything else onto the
 * native Jena value. Keeping the mapping in one place is what keeps the generated members, the
 * SPARQL SELECT and the column types of catalog/streams.json in sync.
 *
 *   logical type | Turtle literal              | PostgreSQL column
 *   -------------|-----------------------------|------------------
 *   iri          | <...>                       | text
 *   string       | "..."                       | text
 *   date         | "2021-04-08"                | text  (plain literal on purpose: Jena maps
 *                |                             |        xsd:date onto XSDDateTime, which JDBC
 *                |                             |        cannot bind)
 *   dateTime     | "..."^^xsd:dateTime         | timestamptz
 *   double       | "1.25"^^xsd:double          | double precision
 *   integer      | "3"^^xsd:int                | integer
 *   wktPoint     | "POINT (...)"^^geo:wktLiteral | text
 */

export const PREFIXES = `@prefix dcterms: <http://purl.org/dc/terms/> .
@prefix env:     <https://openldes.org/ns/env#> .
@prefix geo:     <http://www.opengis.net/ont/geosparql#> .
@prefix locn:    <http://www.w3.org/ns/locn#> .
@prefix org:     <http://www.w3.org/ns/org#> .
@prefix rdfs:    <http://www.w3.org/2000/01/rdf-schema#> .
@prefix sosa:    <http://www.w3.org/ns/sosa/> .
@prefix unit:    <http://qudt.org/vocab/unit/> .
@prefix xsd:     <http://www.w3.org/2001/XMLSchema#> .
`;

export function str(value) {
  return `"${String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n')}"`;
}

export function dateTime(value) {
  return `"${value}"^^xsd:dateTime`;
}

export function double(value) {
  return `"${value}"^^xsd:double`;
}

export function integer(value) {
  return `"${value}"^^xsd:int`;
}

export function wkt(longitude, latitude) {
  return `"POINT (${longitude} ${latitude})"^^geo:wktLiteral`;
}

export function ref(iri) {
  return `<${iri}>`;
}

/** Serialises a member as a single named subject with the given predicate/object pairs. */
export function member(subject, statements) {
  const body = statements
    .filter((statement) => statement !== null && statement !== undefined)
    .map(([predicate, object]) => `    ${predicate} ${object}`)
    .join(' ;\n');

  return `${PREFIXES}\n<${subject}>\n${body} .\n`;
}

/** Serialises a nested blank node, used for the complex data models. */
export function blankNode(statements, indent) {
  const padding = ' '.repeat(indent || 8);
  const body = statements.map(([predicate, object]) => `${padding}${predicate} ${object}`).join(' ;\n');
  return `[\n${body}\n${' '.repeat((indent || 8) - 4)}]`;
}
