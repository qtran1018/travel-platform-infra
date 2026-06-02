-- Splitpush
CREATE USER splitpush_user WITH PASSWORD 'splitpush_pass';
CREATE DATABASE splitpush OWNER splitpush_user;
GRANT ALL PRIVILEGES ON DATABASE splitpush TO splitpush_user;

-- TravelBin
CREATE USER travelbin WITH PASSWORD 'travelbin';
CREATE DATABASE travelbin OWNER travelbin;
GRANT ALL PRIVILEGES ON DATABASE travelbin TO travelbin;

-- Itinerary-Agent
CREATE USER itinerary_user WITH PASSWORD 'itinerary_pass';
CREATE DATABASE itinerary_agent OWNER itinerary_user;
GRANT ALL PRIVILEGES ON DATABASE itinerary_agent TO itinerary_user;
