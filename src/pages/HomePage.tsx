import React from 'react';
import { useAuth } from '../contexts/useAuth';
import { getPreferredDisplayName } from '../lib/userDisplay';
import { CinematicHero } from '../components/home/CinematicHero';
import { StartSection } from '../components/home/StartSection';
import { FeaturesChess } from '../components/home/FeaturesChess';
import { WhyUsGrid } from '../components/home/WhyUsGrid';
import { StatsSection } from '../components/home/StatsSection';
import { Testimonials } from '../components/home/Testimonials';
import { CtaFooter } from '../components/home/CtaFooter';

const HomePage: React.FC = () => {
  const { user, userProfile } = useAuth();
  const displayName = getPreferredDisplayName(user, userProfile);
  const isAuthenticated = Boolean(user);

  return (
    <div className="min-h-screen bg-black text-white">
      <CinematicHero isAuthenticated={isAuthenticated} displayName={displayName} />

      <div className="bg-black">
        <StartSection />
        <FeaturesChess />
        <WhyUsGrid />
        <StatsSection />
        <Testimonials />
        <CtaFooter />
      </div>
    </div>
  );
};

export default HomePage;
