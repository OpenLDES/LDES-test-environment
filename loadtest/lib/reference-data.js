import { mulberry32, pick, between, integerBetween, pad } from './random.js';

/**
 * The realistic basis the whole test environment is built on.
 *
 * These are the members the six streams reference each other through. They are generated from a
 * fixed seed, so `seed.js`, `ldes-loadtest.js` and the PostgreSQL referential integrity checks all
 * derive exactly the same identifiers without having to exchange state.
 *
 * Everything below is modelled on the Flemish surface water monitoring network: water bodies of
 * the Water Framework Directive, the monitoring stations along them, the sensors those stations
 * host, and the air quality stations nearby. The names are real place names; the operators and
 * e-mail addresses deliberately use `example.org`.
 */

export const IDENTIFIER_BASE = 'https://openldes.org/id';

export const REFERENCE_SEED = 20260217;

const WATER_BODIES = [
  { name: 'Schelde', type: 'estuary', longitude: 4.4025, latitude: 51.2194, catchment: 'Beneden-Schelde', areaKm2: 5842.0, lengthKm: 89.4 },
  { name: 'Leie', type: 'river', longitude: 3.2649, latitude: 50.8279, catchment: 'Leiebekken', areaKm2: 1798.5, lengthKm: 76.2 },
  { name: 'Dender', type: 'river', longitude: 4.0355, latitude: 50.9378, catchment: 'Denderbekken', areaKm2: 1384.0, lengthKm: 65.1 },
  { name: 'Demer', type: 'river', longitude: 5.3378, latitude: 50.9307, catchment: 'Demerbekken', areaKm2: 1928.7, lengthKm: 84.7 },
  { name: 'Nete', type: 'river', longitude: 4.5709, latitude: 51.1312, catchment: 'Netebekken', areaKm2: 1673.2, lengthKm: 58.3 },
  { name: 'Albertkanaal', type: 'canal', longitude: 5.5006, latitude: 50.9663, catchment: 'Maasbekken', areaKm2: 942.6, lengthKm: 129.5 },
  { name: 'Kanaal Gent-Terneuzen', type: 'canal', longitude: 3.7174, latitude: 51.0543, catchment: 'Gentse Kanaalzone', areaKm2: 611.4, lengthKm: 32.8 },
  { name: 'IJzer', type: 'river', longitude: 2.8639, latitude: 51.0322, catchment: 'IJzerbekken', areaKm2: 1101.9, lengthKm: 43.6 },
];

const STATIONS = [
  { name: 'Antwerpen-Linkeroever', longitude: 4.3775, latitude: 51.2231, postCode: '2050', postName: 'Antwerpen', thoroughfare: 'Blancefloerlaan', waterBody: 0 },
  { name: 'Temse-Scheldebrug', longitude: 4.2119, latitude: 51.1281, postCode: '9140', postName: 'Temse', thoroughfare: 'Wilfordkaai', waterBody: 0 },
  { name: 'Kortrijk-Bissegem', longitude: 3.2211, latitude: 50.8262, postCode: '8501', postName: 'Kortrijk', thoroughfare: 'Leiekant', waterBody: 1 },
  { name: 'Deinze-Leiemeersen', longitude: 3.5303, latitude: 50.9808, postCode: '9800', postName: 'Deinze', thoroughfare: 'Karel Picquélaan', waterBody: 1 },
  { name: 'Aalst-Centrum', longitude: 4.0392, latitude: 50.9364, postCode: '9300', postName: 'Aalst', thoroughfare: 'Dendermondsesteenweg', waterBody: 2 },
  { name: 'Ninove-Dendersluis', longitude: 4.0264, latitude: 50.8286, postCode: '9400', postName: 'Ninove', thoroughfare: 'Denderkaai', waterBody: 2 },
  { name: 'Hasselt-Godsheide', longitude: 5.3714, latitude: 50.9425, postCode: '3500', postName: 'Hasselt', thoroughfare: 'Demerstraat', waterBody: 3 },
  { name: 'Diest-Webbekom', longitude: 5.0672, latitude: 50.9856, postCode: '3290', postName: 'Diest', thoroughfare: 'Webbekomstraat', waterBody: 3 },
  { name: 'Lier-Duwijck', longitude: 4.5622, latitude: 51.1384, postCode: '2500', postName: 'Lier', thoroughfare: 'Duwijckstraat', waterBody: 4 },
  { name: 'Genk-Zuid', longitude: 5.5183, latitude: 50.9497, postCode: '3600', postName: 'Genk', thoroughfare: 'Zuiderring', waterBody: 5 },
  { name: 'Gent-Rodenhuize', longitude: 3.7861, latitude: 51.1083, postCode: '9042', postName: 'Gent', thoroughfare: 'Rodenhuizekaai', waterBody: 6 },
  { name: 'Diksmuide-IJzerdijk', longitude: 2.8597, latitude: 51.0289, postCode: '8600', postName: 'Diksmuide', thoroughfare: 'IJzerdijk', waterBody: 7 },
];

const OPERATORS = [
  { name: 'Vlaamse Milieumaatschappij', email: 'meetnet@vmm.example.org' },
  { name: 'De Vlaamse Waterweg', email: 'hydrologie@vlaamsewaterweg.example.org' },
  { name: 'Aquafin', email: 'monitoring@aquafin.example.org' },
  { name: 'Provincie Antwerpen - Dienst Water', email: 'water@provincieantwerpen.example.org' },
];

export const OBSERVABLE_PROPERTIES = [
  'ph',
  'dissolved-oxygen',
  'water-temperature',
  'turbidity',
  'electrical-conductivity',
  'nitrate-concentration',
  'ammonium-concentration',
  'chlorophyll-a',
];

export const POLLUTANTS = ['no2', 'pm10', 'pm25', 'o3', 'so2'];

export const SUBSTANCES = [
  { label: 'Ammonium', cas: '7664-41-7', maximum: 45 },
  { label: 'Nitraat', cas: '14797-55-8', maximum: 120 },
  { label: 'Benzeen', cas: '71-43-2', maximum: 8 },
  { label: 'Tolueen', cas: '108-88-3', maximum: 12 },
  { label: 'Cadmium', cas: '7440-43-9', maximum: 2 },
  { label: 'Kwik', cas: '7439-97-6', maximum: 1 },
  { label: 'Glyfosaat', cas: '1071-83-6', maximum: 6 },
  { label: 'Minerale olie', cas: '8042-47-5', maximum: 340 },
];

export const SENSOR_STATUSES = ['operational', 'operational', 'operational', 'maintenance', 'calibration', 'fault'];
export const LEVEL_TRENDS = ['rising', 'falling', 'stable'];
export const QUALITY_FLAGS = ['good', 'good', 'good', 'suspect', 'estimated'];
export const ECOLOGICAL_STATUSES = ['high', 'good', 'moderate', 'poor', 'bad'];
export const CHEMICAL_STATUSES = ['good', 'failing'];
export const INCIDENT_STATUSES = ['reported', 'confirmed', 'contained', 'resolved'];
export const SEVERITY_LEVELS = ['minor', 'moderate', 'major', 'severe'];

function jitter(random, value, spread) {
  return Number((value + (random() - 0.5) * spread).toFixed(5));
}

/**
 * Builds the reference data. `counts` comes from the `seed` section of the catalogue so that the
 * pools and the number of seeded members can never drift apart.
 */
export function buildReferenceData(counts) {
  const random = mulberry32(REFERENCE_SEED);

  const waterBodies = [];
  for (let i = 0; i < counts.waterBodies; i++) {
    const template = WATER_BODIES[i % WATER_BODIES.length];
    const suffix = i < WATER_BODIES.length ? '' : ` - traject ${Math.floor(i / WATER_BODIES.length) + 1}`;

    waterBodies.push({
      code: `WB-${pad(i + 1, 3)}`,
      label: `${template.name}${suffix}`,
      type: template.type,
      longitude: jitter(random, template.longitude, 0.08),
      latitude: jitter(random, template.latitude, 0.05),
      catchmentName: template.catchment,
      catchmentAreaKm2: Number((template.areaKm2 * between(random, 0.95, 1.05)).toFixed(1)),
      lengthKm: Number((template.lengthKm * between(random, 0.9, 1.1)).toFixed(1)),
    });
  }

  const stations = [];
  for (let i = 0; i < counts.monitoringStations; i++) {
    const template = STATIONS[i % STATIONS.length];
    const operator = OPERATORS[i % OPERATORS.length];

    stations.push({
      code: `MS-${pad(i + 1, 3)}`,
      label: `Meetstation ${template.name}`,
      longitude: jitter(random, template.longitude, 0.02),
      latitude: jitter(random, template.latitude, 0.02),
      postCode: template.postCode,
      postName: template.postName,
      thoroughfare: template.thoroughfare,
      operatorName: operator.name,
      operatorEmail: operator.email,
      elevationM: between(random, 1.5, 96.0, 2),
      commissionedOn: `${integerBetween(random, 1998, 2021)}-${pad(integerBetween(random, 1, 12), 2)}-${pad(integerBetween(random, 1, 28), 2)}`,
      waterBodyIndex: template.waterBody % Math.max(waterBodies.length, 1),
    });
  }

  const sensors = [];
  for (let i = 0; i < counts.waterSensors; i++) {
    const station = stations[i % Math.max(stations.length, 1)];
    const property = OBSERVABLE_PROPERTIES[i % OBSERVABLE_PROPERTIES.length];

    sensors.push({
      code: `WS-${pad(i + 1, 4)}`,
      label: `${labelFor(property)} ${station ? station.label.replace('Meetstation ', '') : 'mobiel'}`,
      observedProperty: property,
      serialNumber: `WS-${pad(2015 + (i % 9), 4)}-${pad((i * 37) % 1000, 3)}`,
      installationDepthM: between(random, 0.3, 12.5, 2),
      longitude: station ? jitter(random, station.longitude, 0.01) : jitter(random, 4.4, 1.0),
      latitude: station ? jitter(random, station.latitude, 0.01) : jitter(random, 50.9, 0.6),
      stationIndex: i % Math.max(stations.length, 1),
    });
  }

  // Stations reference a sensor they host and the water body they monitor; water bodies reference
  // a station back. The references are therefore genuinely circular between the two complex
  // streams, which is exactly what the referential integrity checks have to survive.
  stations.forEach((station, index) => {
    const hosted = sensors.filter((sensor) => sensor.stationIndex === index);
    station.sensorCount = Math.max(hosted.length, 1);
    station.primarySensorCode = hosted.length > 0 ? hosted[0].code : sensors[0].code;
  });

  waterBodies.forEach((waterBody, index) => {
    const along = stations.filter((station) => station.waterBodyIndex === index);
    waterBody.primaryStationCode = along.length > 0 ? along[0].code : stations[index % stations.length].code;
  });

  const airQualityStations = [];
  for (let i = 0; i < Math.min(counts.airQualityObservations, 24); i++) {
    const station = stations[i % Math.max(stations.length, 1)];
    airQualityStations.push({
      code: `BE${station.postName.slice(0, 2).toUpperCase()}${pad(i + 1, 3)}`,
      longitude: jitter(random, station.longitude, 0.03),
      latitude: jitter(random, station.latitude, 0.03),
    });
  }

  const gauges = [];
  for (let i = 0; i < Math.min(counts.waterLevelMeasurements, 40); i++) {
    gauges.push({ code: `GAU-${pad(i + 1, 4)}` });
  }

  return {
    waterBodies,
    stations,
    sensors,
    airQualityStations,
    gauges,

    // Identifiers of the seeded observation members. The complex streams only ever reference
    // members from these pools, which guarantees that every foreign key resolves in PostgreSQL.
    seededAirQualityObservations: range(counts.airQualityObservations).map((i) => `AQ-${pad(i + 1, 6)}`),
    seededWaterLevelMeasurements: range(counts.waterLevelMeasurements).map((i) => `WL-${pad(i + 1, 6)}`),
  };
}

function range(count) {
  const values = [];
  for (let i = 0; i < count; i++) {
    values.push(i);
  }
  return values;
}

function labelFor(property) {
  const labels = {
    ph: 'Zuurtegraadsensor',
    'dissolved-oxygen': 'Zuurstofsensor',
    'water-temperature': 'Temperatuursensor',
    turbidity: 'Troebelheidssensor',
    'electrical-conductivity': 'Geleidbaarheidssensor',
    'nitrate-concentration': 'Nitraatsensor',
    'ammonium-concentration': 'Ammoniumsensor',
    'chlorophyll-a': 'Chlorofyl-a-sensor',
  };

  return labels[property] || 'Waterkwaliteitssensor';
}

export function iri(path, code) {
  return `${IDENTIFIER_BASE}/${path}/${code}`;
}

export { pick, between, integerBetween, pad, mulberry32 };
