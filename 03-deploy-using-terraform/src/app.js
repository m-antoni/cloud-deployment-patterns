import express from 'express';
import { PORT, NODE_ENV, API_ENDPOINT, API_KEY } from './config.js';

const app = express();

// Returns a welcome message with the current environment
app.get('/', (req, res) => {
  res.json({
    message: 'Hello from Nodejs App!',
    environment: NODE_ENV,
  });
});

// Fetches weather data from OpenWeatherMap API for a given city
async function getWeather(country) {
  try {
    const response = await fetch(
      `${API_ENDPOINT}/data/2.5/weather?q=${country}&appid=${API_KEY}`,
    );

    return await response.json();
  } catch (error) {
    console.log(error);
  }
}

// Handles GET /weather?q=city and returns the weather data
app.get('/weather', async (req, res) => {
  const country = req.query.q;
  if (!country) {
    return res
      .status(400)
      .json({ error: 'Missing required query parameter: q' });
  }
  try {
    const data = await getWeather(country);
    res.json(data);
  } catch (error) {
    res.status(500).json({ error: 'Failed to fetch weather data' });
  }
});

// Server running
app.listen(PORT, () =>
  console.log(`Server running on port ${PORT} in ${NODE_ENV} mode`),
);
