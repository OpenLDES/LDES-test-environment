import { mulberry32, pick, between, integerBetween, pad, iri } from './reference-data.js';
import {
  SENSOR_STATUSES,
  LEVEL_TRENDS,
  QUALITY_FLAGS,
  ECOLOGICAL_STATUSES,
  CHEMICAL_STATUSES,
  INCIDENT_STATUSES,
  SEVERITY_LEVELS,
  POLLUTANTS,
  SUBSTANCES,
} from './reference-data.js';
import { member, blankNode, str, dateTime, double, integer, wkt, ref } from './rdf.js';

/**
 * Generates the members of the six event streams.
 *
 * Two kinds of stream are produced:
 *
 *  - *versioned* streams (water-sensors, monitoring-stations, water-bodies) publish a new version
 *    of one of the seeded reference members, round robin. The set of distinct `dcterms:isVersionOf`
 *    values therefore stays exactly as large as the reference pool;
 *  - *append* streams (air-quality-observations, water-level-measurements, pollution-incidents)
 *    publish a new member for every sequence number.
 *
 * `sequence` is globally unique per stream across the seeding run and the load test, which is what
 * makes the version IRIs unique without any shared state: the version IRI is derived from a
 * synthetic `dcterms:created` timestamp that is itself a pure function of the sequence number.
 *
 * Spreading `dcterms:created` over a window of several days is deliberate. The time based views
 * fragment on that property, so a run that writes every member within the same minute would only
 * ever produce a single fragment and would not exercise the fragmentation at all.
 */

const POLLUTANT_RANGES = {
  no2: [5, 80],
  pm10: [5, 70],
  pm25: [3, 45],
  o3: [10, 120],
  so2: [1, 25],
};

const DAY_MS = 24 * 60 * 60 * 1000;

export function createGenerator(catalog, reference, options) {
  const settings = options || {};
  const historyWindowMs = (settings.historyDays || 7) * DAY_MS;
  const endMs = settings.endMs || Date.now();
  const streams = {};

  for (const stream of catalog.streams) {
    const expected = Math.max(settings.expectedMembers[stream.name] || 1, 1);
    streams[stream.name] = {
      definition: stream,
      strideMs: Math.max(1, Math.floor(historyWindowMs / expected)),
      startMs: endMs - historyWindowMs,
    };
  }

  function timestamps(streamName, sequence) {
    const stream = streams[streamName];
    const createdMs = stream.startMs + sequence * stream.strideMs;
    return new Date(createdMs).toISOString();
  }

  function build(streamName, sequence) {
    const stream = streams[streamName];
    if (!stream) {
      throw new Error(`Unknown stream ${streamName}`);
    }

    const created = timestamps(streamName, sequence);
    const random = mulberry32(hash(streamName) + sequence * 2654435761);
    const context = { definition: stream.definition, created, random, sequence, reference };

    return GENERATORS[streamName](context);
  }

  return { build, timestamps };
}

function hash(value) {
  let result = 2166136261;
  for (let i = 0; i < value.length; i++) {
    result ^= value.charCodeAt(i);
    result = Math.imul(result, 16777619);
  }
  return result >>> 0;
}

function versionIri(memberIri, created) {
  return `${memberIri}/${created}`;
}

function shift(created, random, maximumMinutes) {
  const offset = Math.floor(random() * maximumMinutes) * 60 * 1000;
  return new Date(Date.parse(created) - offset).toISOString();
}

const GENERATORS = {
  'water-sensors': ({ created, random, sequence, reference }) => {
    const sensor = reference.sensors[sequence % reference.sensors.length];
    const memberIri = iri('water-sensor', sensor.code);

    return {
      memberIri,
      versionIri: versionIri(memberIri, created),
      body: member(versionIri(memberIri, created), [
        ['a', 'sosa:Sensor'],
        ['dcterms:isVersionOf', ref(memberIri)],
        ['dcterms:created', dateTime(created)],
        ['rdfs:label', str(sensor.label)],
        ['sosa:observes', ref(iri('observable-property', sensor.observedProperty))],
        ['env:serialNumber', str(sensor.serialNumber)],
        ['env:operationalStatus', str(pick(random, SENSOR_STATUSES))],
        ['env:installationDepth', double(sensor.installationDepthM)],
        ['sosa:isHostedBy', ref(iri('monitoring-station', reference.stations[sensor.stationIndex].code))],
        ['geo:asWKT', wkt(sensor.longitude, sensor.latitude)],
      ]),
    };
  },

  'air-quality-observations': ({ created, random, sequence, reference }) => {
    const code = `AQ-${pad(sequence + 1, 6)}`;
    const memberIri = iri('air-quality-observation', code);
    const station = reference.airQualityStations[sequence % reference.airQualityStations.length];
    const pollutant = pick(random, POLLUTANTS);
    const range = POLLUTANT_RANGES[pollutant];

    return {
      memberIri,
      versionIri: versionIri(memberIri, created),
      body: member(versionIri(memberIri, created), [
        ['a', 'sosa:Observation'],
        ['dcterms:isVersionOf', ref(memberIri)],
        ['dcterms:created', dateTime(created)],
        ['sosa:observedProperty', ref(iri('pollutant', pollutant))],
        ['sosa:hasSimpleResult', double(between(random, range[0], range[1], 2))],
        ['env:unit', 'unit:MicroGM-PER-M3'],
        ['sosa:resultTime', dateTime(shift(created, random, 15))],
        ['env:stationCode', str(station.code)],
        ['env:airQualityIndex', integer(integerBetween(random, 1, 10))],
        ['geo:asWKT', wkt(station.longitude, station.latitude)],
      ]),
    };
  },

  'water-level-measurements': ({ created, random, sequence, reference }) => {
    const code = `WL-${pad(sequence + 1, 6)}`;
    const memberIri = iri('water-level-measurement', code);
    const gauge = reference.gauges[sequence % reference.gauges.length];

    return {
      memberIri,
      versionIri: versionIri(memberIri, created),
      body: member(versionIri(memberIri, created), [
        ['a', 'sosa:Observation'],
        ['dcterms:isVersionOf', ref(memberIri)],
        ['dcterms:created', dateTime(created)],
        ['env:gaugeCode', str(gauge.code)],
        ['sosa:hasSimpleResult', double(between(random, -1.5, 8.5, 3))],
        ['env:unit', 'unit:M'],
        ['sosa:resultTime', dateTime(shift(created, random, 10))],
        ['env:trend', str(pick(random, LEVEL_TRENDS))],
        ['env:qualityFlag', str(pick(random, QUALITY_FLAGS))],
      ]),
    };
  },

  'monitoring-stations': ({ created, random, sequence, reference }) => {
    const station = reference.stations[sequence % reference.stations.length];
    const memberIri = iri('monitoring-station', station.code);
    const waterBody = reference.waterBodies[station.waterBodyIndex];
    const hosted = reference.sensors
      .filter((sensor) => sensor.stationIndex === sequence % reference.stations.length)
      .slice(0, 3);

    return {
      memberIri,
      versionIri: versionIri(memberIri, created),
      body: member(versionIri(memberIri, created), [
        ['a', 'env:MonitoringStation'],
        ['a', 'sosa:Platform'],
        ['dcterms:isVersionOf', ref(memberIri)],
        ['dcterms:created', dateTime(created)],
        ['rdfs:label', str(station.label)],
        ['env:primarySensor', ref(iri('water-sensor', station.primarySensorCode))],
        ['env:sensorCount', integer(station.sensorCount)],
        ['env:monitors', ref(iri('water-body', waterBody.code))],
        [
          'locn:address',
          blankNode([
            ['a', 'locn:Address'],
            ['locn:postCode', str(station.postCode)],
            ['locn:postName', str(station.postName)],
            ['locn:thoroughfare', str(station.thoroughfare)],
          ]),
        ],
        [
          'env:operator',
          blankNode([
            ['a', 'org:Organization'],
            ['rdfs:label', str(station.operatorName)],
            ['env:contactEmail', str(station.operatorEmail)],
          ]),
        ],
        ['env:elevation', double(station.elevationM)],
        ['env:commissionedAt', str(station.commissionedOn)],
        ['geo:asWKT', wkt(station.longitude, station.latitude)],
        // Multi valued on purpose: the sink query deliberately ignores it, because a multi valued
        // predicate in the SPARQL SELECT would turn one member into several rows.
        ...hosted.map((sensor) => ['sosa:hosts', ref(iri('water-sensor', sensor.code))]),
      ]),
    };
  },

  'water-bodies': ({ created, random, sequence, reference }) => {
    const waterBody = reference.waterBodies[sequence % reference.waterBodies.length];
    const memberIri = iri('water-body', waterBody.code);
    const levelMeasurement = pick(random, reference.seededWaterLevelMeasurements);

    return {
      memberIri,
      versionIri: versionIri(memberIri, created),
      body: member(versionIri(memberIri, created), [
        ['a', 'env:WaterBody'],
        ['dcterms:isVersionOf', ref(memberIri)],
        ['dcterms:created', dateTime(created)],
        ['rdfs:label', str(waterBody.label)],
        ['env:waterBodyType', str(waterBody.type)],
        ['env:primaryStation', ref(iri('monitoring-station', waterBody.primaryStationCode))],
        ['env:latestLevelMeasurement', ref(iri('water-level-measurement', levelMeasurement))],
        [
          'env:qualityAssessment',
          blankNode([
            ['a', 'env:QualityAssessment'],
            ['env:ecologicalStatus', str(pick(random, ECOLOGICAL_STATUSES))],
            ['env:chemicalStatus', str(pick(random, CHEMICAL_STATUSES))],
            ['dcterms:date', str(created.slice(0, 10))],
          ]),
        ],
        [
          'env:catchment',
          blankNode([
            ['a', 'env:Catchment'],
            ['rdfs:label', str(waterBody.catchmentName)],
            ['env:areaKm2', double(waterBody.catchmentAreaKm2)],
          ]),
        ],
        ['env:lengthKm', double(waterBody.lengthKm)],
        ['geo:asWKT', wkt(waterBody.longitude, waterBody.latitude)],
      ]),
    };
  },

  'pollution-incidents': ({ created, random, sequence, reference }) => {
    const code = `PI-${pad(sequence + 1, 6)}`;
    const memberIri = iri('pollution-incident', code);
    const waterBody = pick(random, reference.waterBodies);
    const station = pick(random, reference.stations);
    const sensor = pick(random, reference.sensors);
    const observation = pick(random, reference.seededAirQualityObservations);
    const substance = pick(random, SUBSTANCES);

    return {
      memberIri,
      versionIri: versionIri(memberIri, created),
      body: member(versionIri(memberIri, created), [
        ['a', 'env:PollutionIncident'],
        ['dcterms:isVersionOf', ref(memberIri)],
        ['dcterms:created', dateTime(created)],
        ['env:affectedWaterBody', ref(iri('water-body', waterBody.code))],
        ['env:reportedByStation', ref(iri('monitoring-station', station.code))],
        ['env:detectedBySensor', ref(iri('water-sensor', sensor.code))],
        ['env:corroboratingObservation', ref(iri('air-quality-observation', observation))],
        ['env:status', str(pick(random, INCIDENT_STATUSES))],
        ['env:detectedAt', dateTime(shift(created, random, 240))],
        [
          'env:severityAssessment',
          blankNode([
            ['a', 'env:SeverityAssessment'],
            ['env:severityLevel', str(pick(random, SEVERITY_LEVELS))],
            ['env:confidence', double(between(random, 0.35, 0.99, 2))],
            ['dcterms:date', dateTime(shift(created, random, 60))],
          ]),
        ],
        [
          'env:substance',
          blankNode([
            ['a', 'env:Substance'],
            ['rdfs:label', str(substance.label)],
            ['env:casNumber', str(substance.cas)],
            ['env:concentration', double(between(random, 0.01, substance.maximum, 3))],
            ['env:unit', 'unit:MilliGM-PER-L'],
          ]),
        ],
        ['geo:asWKT', wkt(jitterLongitude(waterBody, random), jitterLatitude(waterBody, random))],
      ]),
    };
  },
};

function jitterLongitude(waterBody, random) {
  return Number((waterBody.longitude + (random() - 0.5) * 0.1).toFixed(5));
}

function jitterLatitude(waterBody, random) {
  return Number((waterBody.latitude + (random() - 0.5) * 0.06).toFixed(5));
}
